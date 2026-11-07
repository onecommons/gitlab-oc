# frozen_string_literal: true

module OC
  module WorkItems
    # Applies the offline edits one push made to this installation's issue
    # files, as the pusher. ItemEditCheck has already refused any push it could
    # not apply; this does the work after the push lands.
    class ItemEditsWorker
      include ApplicationWorker
      include ExclusiveLeaseGuard

      data_consistency :sticky
      sidekiq_options retry: 3
      feature_category :source_code_management
      urgency :low
      defer_on_database_health_signal :gitlab_main_org, %i[issues notes], 1.minute
      idempotent!

      RETRY_DELAY = 30.seconds

      def perform(project_id, user_id, oldrev, newrev)
        @project = ::Project.find_by_id(project_id)
        return unless @project&.work_items_sync_enabled?

        user = ::User.find_by_id(user_id)
        return unless user

        # try_obtain_lease returns the block's value, which says nothing about
        # whether the lease was held.
        held = false
        try_obtain_lease do
          held = true
          ItemEditService.new(@project, user).execute(oldrev, newrev)
        end

        self.class.perform_in(RETRY_DELAY, project_id, user_id, oldrev, newrev) unless held
      end

      private

      # Per project: two pushes' edits to one issue must not interleave.
      def lease_key
        "#{self.class.name.underscore}:#{@project.id}"
      end

      def lease_timeout
        10.minutes
      end
    end
  end
end
