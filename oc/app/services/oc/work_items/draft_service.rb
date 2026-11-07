# frozen_string_literal: true

module OC
  module WorkItems
    # Creates issues from the drafts waiting in this installation's
    # `<uuid>/_incoming/` on the sync branch, as the user whose push triggered
    # the run. See DraftFile for the format.
    #
    # Through Issues::CreateService rather than the import machinery: a draft is
    # a new issue made by a person now, so it gets the normal permission checks,
    # notifications, webhooks and system notes. That service quietly drops
    # fields the user may not set, so #preflight checks them first and a draft
    # that would lose any is left in place and reported instead -- an issue
    # that differs from its file with nothing to show it is worse than none.
    #
    # Publishing the issue and deleting its draft is the sync's job: creating
    # the issue enqueues it (OC::Issues::BaseService).
    class DraftService
      include BranchTree

      BATCH_SIZE = 100

      # How far back pass 2 looks for draft-made issues still carrying
      # `#draft:` text. Long enough for a stopped run to be picked up by the
      # next push; short enough that a description someone wrote `#draft:`
      # into later is left alone.
      REWRITE_WINDOW = 7.days

      Result = Struct.new(:created, :skipped, :stale, :more, keyword_init: true)

      def initialize(project, user)
        @project = project
        @user = user
        @repository = project.repository
      end

      # Creates up to BATCH_SIZE drafts. `more` says whether any are left for
      # another job.
      def execute
        result = Result.new(created: [], skipped: {}, stale: [], more: false)
        return result unless @user && head_sha

        result.stale, pending = waiting_drafts.partition { |path| recorded_keys.include?(DraftFile.key_for(path)) }

        # Counted in creations, not drafts looked at: a draft that is refused
        # stays on the branch and sorts where it sorts, so a batch of the first
        # BATCH_SIZE paths could be all refusals forever and never reach the rest.
        pending.each_with_index do |path, index|
          if result.created.size == BATCH_SIZE
            result.more = index < pending.size
            break
          end

          outcome = create(path)
          outcome.is_a?(::Issue) ? result.created << outcome : result.skipped[DraftFile.key_for(path)] = outcome
        end

        rewrite_references unless result.more
        log_skipped(result.skipped)
        result
      end

      # Why `draft` cannot be created by this user, or nil when it can. Reads
      # only; shared with the message a push prints, so the two cannot disagree.
      def preflight(draft)
        # Not @project.issues.build, which would leave it in the association.
        issue = ::Issue.new(project: @project, namespace: @project.project_namespace)
        return 'you cannot create issues in this project' unless can?(:create_issue, @project)

        if metadata?(draft) && !can?(:set_issue_metadata, issue)
          return 'you cannot set labels, a milestone, assignees or a due date here'
        end

        return 'confidential drafts are only created on private projects' if draft.confidential? && !@project.private?
        return 'you cannot create confidential issues here' if draft.confidential? && !can?(:set_confidentiality, issue)

        assignee_problem(draft, issue) || label_problem(draft) || milestone_problem(draft)
      end

      private

      # Pass 2: once every waiting draft has an issue, point each `#draft:<key>`
      # at the issue it became. Covers drafts created by earlier jobs of the same
      # push, and a run that stopped between the two passes, by looking at every
      # recent draft-made issue still carrying the text rather than only this
      # job's.
      #
      # Saved on the model, not through Issues::UpdateService: that would add a
      # "changed the description" note to a brand-new issue. Saving still
      # refreshes the rendered description and the mention index; the sync is
      # enqueued here because only the services enqueue it.
      # rubocop:disable CodeReuse/ActiveRecord -- the drafts table has no finder
      def rewrite_references
        drafts = OC::WorkItems::Draft.for_project(@project)
        recent = drafts.where(created_at: REWRITE_WINDOW.ago..).where.not(issue_id: nil).includes(:issue)
        return if recent.none? { |row| row.issue.description&.include?('#draft:') }

        # Every key, not only recent ones: a new draft may name an old key.
        iids_by_key = drafts.pluck(:key, :iid).to_h

        recent.each do |row|
          issue = row.issue
          rewritten = DraftFile.rewrite_references(issue.description, iids_by_key)
          next if rewritten == issue.description

          issue.update!(description: rewritten)
          OC::WorkItems.enqueue_sync(issue, @user)
        end
      end
      # rubocop:enable CodeReuse/ActiveRecord

      # One draft is allowed to fail, and only that draft -- the import's stance.
      def create(path)
        draft = DraftFile.parse(read(path), path: path)
        problem = preflight(draft)
        return problem if problem

        # The issue and its row in one transaction: an issue with no row would
        # be created again by the retry of a job that failed in between. The
        # sync trigger fires inline, and a job may not be queued inside a
        # transaction, so it is held back and queued once the row is committed.
        issue = ::ApplicationRecord.transaction do
          created = OC::WorkItems.suppress_sync { create_issue(draft) }
          next created unless created.is_a?(::Issue)

          OC::WorkItems::Draft.create!(project: @project, issue: created, key: draft.key, iid: created.iid)
          created
        end

        OC::WorkItems.enqueue_sync(issue, @user) if issue.is_a?(::Issue)
        issue
      rescue DraftFile::Error => error
        # Only a draft that bypassed the push check (a merge, a purge replay).
        "it could not be read: #{error.message}"
      rescue ::StandardError => error
        ::Gitlab::ErrorTracking.track_exception(error, project_id: @project.id, draft: path)
        "it could not be created: #{error.message}"
      end

      def create_issue(draft)
        response = ::Issues::CreateService.new(
          container: @project, current_user: @user, params: issue_params(draft), perform_spam_check: false
        ).execute

        return response.errors.to_sentence.presence || 'the issue could not be created' unless response.success?

        issue = response[:issue]
        return issue if issue.work_item_type.base_type == draft.type

        # The type was refused rather than created wrongly; the issue exists, so
        # it is kept and reported rather than created again.
        log_skipped(draft.key => "created as #{issue.work_item_type.base_type}, not #{draft.type}")
        issue
      end

      def issue_params(draft)
        {
          title: draft.title,
          description: draft.description,
          issue_type: draft.type,
          confidential: draft.confidential?,
          due_date: draft.due_date,
          label_ids: labels_for(draft).map(&:id),
          milestone_id: milestone_for(draft)&.id,
          assignee_ids: assignees_for(draft).map(&:id)
        }.compact
      end

      def metadata?(draft)
        draft.labels.any? || draft.milestone || draft.assignees.any? || draft.due_date
      end

      def assignee_problem(draft, issue)
        return if draft.assignees.empty?
        return 'only one assignee is allowed' if draft.assignees.size > 1 && !issue.allows_multiple_assignees?

        found = assignees_for(draft)
        # by_username matches case-insensitively, so compare the same way.
        known = found.map { |user| user.username.downcase }
        missing = draft.assignees.reject { |name| known.include?(name.downcase) }
        return "no user #{missing.first} can be assigned here" if missing.any?

        unreadable = found.find { |assignee| !Ability.allowed?(assignee, :read_issue, @project) }
        "#{unreadable.username} cannot be assigned here" if unreadable
      end

      # rubocop:disable Gitlab/Authz/PermissionCheck -- the abilities Labels:: and Milestones::FindOrCreateService check
      def label_problem(draft)
        missing = draft.labels.find { |title| label_service(title).execute(find_only: true).nil? }
        return unless missing && !can?(:admin_label, @project)

        "label #{missing.inspect} does not exist, and you cannot create labels"
      end

      def milestone_problem(draft)
        return unless draft.milestone
        return if existing_milestone(draft.milestone) || can?(:admin_milestone, @project)

        "milestone #{draft.milestone.inspect} does not exist, and you cannot create milestones"
      end
      # rubocop:enable Gitlab/Authz/PermissionCheck

      # Found by title across the project's ancestor groups, else created on
      # the project -- what importing does.
      def labels_for(draft)
        draft.labels.filter_map { |title| label_service(title).execute }
      end

      def milestone_for(draft)
        return unless draft.milestone

        ::Milestones::FindOrCreateService.new(@project, @user, 'title' => draft.milestone).execute
      end

      def existing_milestone(title)
        groups = @project.group&.self_and_ancestors_ids
        ::Milestone.for_projects_and_groups([@project.id], groups).find_by(title: title) # rubocop:disable CodeReuse/ActiveRecord -- Milestones::FindOrCreateService's own lookup
      end

      def assignees_for(draft)
        return [] if draft.assignees.empty?

        ::User.by_username(draft.assignees).to_a
      end

      def label_service(title)
        ::Labels::FindOrCreateService.new(@user, @project, title: title, include_ancestor_groups: true)
      end

      def can?(ability, subject)
        Ability.allowed?(@user, ability, subject)
      end

      # Paths of the drafts waiting in our inbox, in file-name order.
      def waiting_drafts
        @waiting_drafts ||= begin
          inbox = "#{OC::WorkItems.instance_directory}/#{DraftFile::DIRECTORY}"

          blob_oids_at(@repository, head_sha, inbox).keys
            .select { |path| DraftFile.draft_path?(path, OC::WorkItems.instance_directory) }
            .sort
        end
      end

      # rubocop:disable CodeReuse/ActiveRecord -- one indexed lookup per run
      def recorded_keys
        @recorded_keys ||= OC::WorkItems::Draft.for_project(@project)
          .where(key: waiting_drafts.map { |path| DraftFile.key_for(path) })
          .pluck(:key).to_set
      end
      # rubocop:enable CodeReuse/ActiveRecord

      def read(path)
        blob = @repository.blob_at(head_sha, path)
        too_large = blob.size > OC::Gitlab::Checks::DraftFileCheck::MAX_BYTES
        raise DraftFile::Error.new('is too large', path: path) if too_large

        blob.load_all_data!
        blob.data
      end

      def head_sha
        @head_sha ||= @repository.commit(SYNC_BRANCH)&.sha
      end

      def log_skipped(skipped)
        skipped.each do |key, reason|
          ::Gitlab::AppLogger.info(
            message: "work item drafts skipped: #{key}: #{reason}",
            project_id: @project.id, ::Labkit::Fields::GL_USER_ID => @user&.id)
        end
      end
    end
  end
end
