# frozen_string_literal: true

module OC
  module WorkItems
    # Creates issues from drafts pushed to the sync branch, as the pusher.
    # Enqueued on every push to the branch, beside ImportWorker; separate from
    # it because the gate differs (creating an issue, not deleting one) and a
    # push that only adds drafts should not run an import pass.
    class DraftsWorker
      include ApplicationWorker
      include ExclusiveLeaseGuard

      data_consistency :sticky
      sidekiq_options retry: 3
      feature_category :source_code_management
      urgency :low
      defer_on_database_health_signal :gitlab_main_org, %i[issues], 1.minute
      idempotent!
      deduplicate :until_executing, including_scheduled: true

      # A run that could not take the lease tries again after this long, so a
      # push arriving mid-run is not lost.
      RETRY_DELAY = 30.seconds

      def perform(project_id, user_id)
        @project = ::Project.find_by_id(project_id)
        return unless @project

        # With sync off, a created issue would never be published nor its draft
        # removed, so drafts wait for sync to be turned on.
        unless @project.work_items_sync_enabled?
          ::Gitlab::AppLogger.info(message: 'work item drafts skipped: work items sync is off',
            project_id: project_id)
          return
        end

        user = ::User.find_by_id(user_id)
        return unless user

        # try_obtain_lease returns the block's value, which says nothing about
        # whether the lease was held, so that is recorded separately.
        held = false
        try_obtain_lease do
          held = true
          result = DraftService.new(@project, user).execute
          self.class.perform_async(project_id, user_id) if result.more
        end

        self.class.perform_in(RETRY_DELAY, project_id, user_id) unless held
      end

      private

      # Per project: two pushes must not both create the same draft.
      def lease_key
        "#{self.class.name.underscore}:#{@project.id}"
      end

      def lease_timeout
        10.minutes
      end
    end
  end
end
