# frozen_string_literal: true

module OC
  module WorkItems
    class SyncWorker
      include ApplicationWorker

      data_consistency :sticky
      sidekiq_options retry: 3
      feature_category :source_code_management
      urgency :low
      defer_on_database_health_signal :gitlab_main_org, %i[issues notes], 1.minute
      idempotent!
      # Coalescing: jobs are enqueued with perform_in(sync_delay), and
      # duplicates arriving while one is scheduled/queued are dropped, so a
      # burst of changes to one issuable becomes a single run. The lock is
      # released when execution STARTS (:until_executing), so a change
      # landing mid-run schedules a catch-up run instead of being lost.
      # (:until_executed + if_deduplicated: :reschedule_once would NOT work
      # here: reschedulable? is false for scheduled jobs in this version.)
      deduplicate :until_executing, including_scheduled: true

      # rubocop: disable CodeReuse/ActiveRecord -- the query belongs to the sync and has no finder
      def perform(project_id, issuable_type, issuable_id, issuable_iid, user_id = nil)
        project = ::Project.find_by(id: project_id)
        return unless project&.work_items_sync_enabled?

        # No branch yet means the project was never synced -- backfill
        # everything (including this change) instead.
        unless project.repository.branch_exists?(SYNC_BRANCH)
          FullSyncWorker.perform_async(project.id)
          return
        end

        user = user_id && ::User.find_by(id: user_id)
        service = SyncService.new(project, triggered_by: user)
        issuable = find_issuable(project, issuable_type, issuable_id)

        if issuable
          service.execute([issuable])
        else
          # Deleted (or moved) issuable -- drop its file.
          service.remove(issuable_type, issuable_iid)
        end
      rescue ::Gitlab::Git::PreReceiveError => e
        # Permission failures (e.g. a protection rule on the sync branch) are
        # permanent; retrying would only spam Gitaly.
        ::Gitlab::AppLogger.warn(
          message: 'work items sync rejected by pre-receive check',
          project_id: project_id, error: e.message)
      end

      private

      def find_issuable(project, issuable_type, issuable_id)
        case issuable_type
        when 'Issue' then project.issues.find_by(id: issuable_id)
        when 'MergeRequest' then project.merge_requests.find_by(id: issuable_id)
        end
      end
      # rubocop: enable CodeReuse/ActiveRecord
    end
  end
end
