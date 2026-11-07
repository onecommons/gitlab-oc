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

      def initialize(project, user)
        @project = project
        @user = user
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
