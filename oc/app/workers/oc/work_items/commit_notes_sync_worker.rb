# frozen_string_literal: true

module OC
  module WorkItems
    # Syncs commit_notes/<sha>.yml after a note on that commit was added,
    # edited, deleted, or had an award emoji toggled.
    #
    # Separate from SyncWorker because the unit of work is a commit sha rather
    # than a record: there is nothing to look up and nothing to remove by iid,
    # the file is simply rebuilt from whatever notes the sha still has (and
    # deleted when it has none).
    class CommitNotesSyncWorker
      include ApplicationWorker

      data_consistency :sticky
      sidekiq_options retry: 3
      feature_category :source_code_management
      urgency :low
      defer_on_database_health_signal :gitlab_main_org, %i[issues notes], 1.minute
      idempotent!
      # Same coalescing as SyncWorker: the lock is released when execution
      # starts, so a note landing mid-run schedules a catch-up instead of
      # being dropped. Dedup is per (project, sha) -- the key is the argument
      # array -- so busy commits coalesce without starving quiet ones.
      deduplicate :until_executing, including_scheduled: true

      # rubocop: disable CodeReuse/ActiveRecord -- the query belongs to the sync and has no finder
      def perform(project_id, commit_id, user_id = nil)
        project = ::Project.find_by(id: project_id)
        return unless project&.work_items_sync_enabled?

        # No branch yet means the project was never synced -- backfill
        # everything (including this change) instead.
        unless project.repository.branch_exists?(SYNC_BRANCH)
          FullSyncWorker.perform_async(project.id)
          return
        end

        user = user_id && ::User.find_by(id: user_id)

        SyncService.new(project, triggered_by: user).execute_commit_notes([commit_id])
      rescue ::Gitlab::Git::PreReceiveError => e
        # Permission failures (e.g. a protection rule on the sync branch) are
        # permanent; retrying would only spam Gitaly.
        ::Gitlab::AppLogger.warn(
          message: 'work items commit notes sync rejected by pre-receive check',
          project_id: project_id, ::Labkit::Fields::ERROR_MESSAGE => e.message)
      end
      # rubocop: enable CodeReuse/ActiveRecord
    end
  end
end
