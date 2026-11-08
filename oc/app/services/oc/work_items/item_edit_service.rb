# frozen_string_literal: true

module OC
  module WorkItems
    # Applies offline edits (ItemEdit) to this installation's issues, as the
    # user whose push carried them.
    #
    # #preflight is shared with the push check, so a push is refused for
    # exactly what this would not do. Like drafts, it checks what the services
    # would otherwise drop without a word: an edit that is partly applied is
    # worse than a refused push.
    class ItemEditService
      include IssueMetadata

      METADATA_FIELDS = %w[due_date label_links milestone].freeze
      UPDATE_FIELDS = %w[title description confidential due_date].freeze

      Result = Struct.new(:applied, :skipped, keyword_init: true)

      def initialize(project, user)
        @project = project
        @user = user
      end

      # Applies the edits a push from oldrev to newrev made. Reads the two
      # revisions rather than the branch, which the sync may have rewritten
      # since. Returns the iids applied and {iid => reason} for those skipped.
      def execute(oldrev, newrev)
        result = Result.new(applied: [], skipped: {})

        ItemEdit.changed_paths(project.repository, oldrev, newrev).each do |path|
          edit = ItemEdit.diff(path: path, old_yaml: content_at(oldrev, path), new_yaml: content_at(newrev, path))
          next if edit.empty?

          outcome = apply(edit)
          outcome.is_a?(String) ? result.skipped[edit.iid] = outcome : result.applied << edit.iid
        rescue ItemEdit::Error => error
          result.skipped[ItemEdit.iid_for(path)] = error.message
        end

        log(result)
        result
      end

      # Why `edit` cannot be applied to `issue` by this user, or nil when it
      # can. Reads only.
      def preflight(edit, issue)
        fields = edit.fields
        return 'you cannot edit this issue' unless can?(:update_issue, issue)
        return 'you cannot reopen this issue' if fields['state']&.last == 'opened' && !can?(:reopen_issue, issue)

        if fields.keys.intersect?(METADATA_FIELDS) && !can?(:set_issue_metadata, issue)
          return 'you cannot set labels, a milestone or a due date here'
        end

        if fields.key?('confidential') && !can?(:set_confidentiality, issue)
          return 'you cannot change whether this issue is confidential'
        end

        return 'you cannot comment on this issue' if edit.new_notes.any? && !can?(:create_note, issue)

        metadata_problem(fields) || edited_notes_problem(edit, issue)
      end

      # The database row for a comment in an issue file, which carries no ids.
      # created_at is written to the millisecond, so it is matched to one.
      # rubocop:disable CodeReuse/ActiveRecord -- the file's identity of a comment has no finder
      def find_note(issue, edited_note)
        created_at = ::Time.iso8601(edited_note.created_at.to_s)

        issue.notes.where(
          author_id: edited_note.author_id,
          discussion_id: edited_note.discussion_id,
          created_at: created_at...(created_at + 0.001)
        ).first
      rescue ArgumentError
        nil
      end
      # rubocop:enable CodeReuse/ActiveRecord

      private

      attr_reader :project, :user

      # One issue is allowed to fail, and only that issue. Returns the issue,
      # or why it was skipped. A skipped issue is synced, so the branch does
      # not go on showing an edit nobody applied.
      def apply(edit)
        issue = project.issues.find_by_iid(edit.iid)
        return 'the issue no longer exists' unless issue

        outcome = apply_to(issue, edit)
        OC::WorkItems.enqueue_sync(issue, user) if outcome.is_a?(String)
        outcome
      end

      def apply_to(issue, edit)
        current = RecordSerializer.new.to_yaml(issue)
        return 'the issue cannot be edited offline' unless current.is_a?(String)

        # Someone changed a field on the web between the push check and now.
        statuses = edit.statuses(current, author_id: user.id)
        conflict = statuses.find { |_key, status| status == :conflict }&.first
        return "#{ItemEdit.describe(conflict)} changed after the push" if conflict

        problem = preflight(edit, issue)
        return problem if problem

        pending = statuses.filter_map { |key, status| key if status == :pending }
        update_issue(issue, edit, pending)
        edit_notes(issue, pending.grep(ItemEdit::EditedNote))
        create_notes(issue, pending.grep(ItemEdit::NewNote))
        issue
      rescue ::StandardError => error
        ::Gitlab::ErrorTracking.track_exception(error, project_id: project.id, iid: edit.iid)
        "it could not be applied: #{error.message}"
      end

      def update_issue(issue, edit, pending)
        params = update_params(edit, pending)
        if params.any?
          ::Issues::UpdateService.new(container: project, current_user: user, params: params).execute(issue)
          raise issue.errors.full_messages.to_sentence if issue.errors.any?
        end

        return unless pending.include?('state')

        if edit.fields['state'].last == 'closed'
          ::Issues::CloseService.new(container: project, current_user: user).execute(issue)
        else
          ::Issues::ReopenService.new(container: project, current_user: user).execute(issue)
        end
      end

      def update_params(edit, pending)
        params = (pending & UPDATE_FIELDS).to_h { |field| [field.to_sym, edit.fields[field].last] }

        if pending.include?('label_links')
          old_titles, new_titles = edit.fields['label_links']
          params[:add_label_ids] = labels_for(new_titles - old_titles).map(&:id)
          params[:remove_label_ids] = (old_titles - new_titles).filter_map do |title|
            label_service(title).execute(find_only: true)&.id
          end
        end

        params[:milestone_id] = milestone_for(edit.fields['milestone'].last)&.id if pending.include?('milestone')
        params
      end

      def edit_notes(issue, edited_notes)
        edited_notes.each do |edited_note|
          note = find_note(issue, edited_note)
          ::Notes::UpdateService.new(project, user, note: edited_note.note).execute(note)
        end
      end

      def create_notes(issue, new_notes)
        new_notes.each do |new_note|
          ::Notes::CreateService.new(project, user, noteable: issue, note: new_note.note).execute
        end
      end

      # The job can run after the push's revisions are gone (a force push and
      # a garbage collection in between).
      def content_at(revision, path)
        blob = project.repository.blob_at(revision, path)
        raise ItemEdit::Error.new("is no longer in the repository at #{revision}", path: path) unless blob

        blob.load_all_data!
        blob.data
      end

      def log(result)
        result.skipped.each do |iid, reason|
          ::Gitlab::AppLogger.info(message: "work item edits skipped: ##{iid}: #{reason}",
            project_id: project.id, ::Labkit::Fields::GL_USER_ID => user.id)
        end
      end

      def metadata_problem(fields)
        old_labels, new_labels = fields['label_links']
        problem = label_problem(Array(new_labels) - Array(old_labels)) if fields.key?('label_links')

        problem || (milestone_problem(fields['milestone'].last) if fields.key?('milestone'))
      end

      def edited_notes_problem(edit, issue)
        edit.edited_notes.each do |edited_note|
          note = find_note(issue, edited_note)
          what = "the comment of #{edited_note.created_at}"
          return "#{what} no longer exists" unless note

          # rubocop:disable Gitlab/Authz/PermissionCheck -- what NotesActions#authorize_admin_note! checks; Notes::UpdateService does not
          return "you can only change your own comments, and #{what} is not yours" unless
            note.author_id == @user.id && can?(:admin_note, note)
          # rubocop:enable Gitlab/Authz/PermissionCheck
        end

        nil
      end
    end
  end
end
