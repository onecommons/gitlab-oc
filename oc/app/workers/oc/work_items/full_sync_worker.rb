# frozen_string_literal: true

module OC
  module WorkItems
    # Backfills or reconciles the whole sync branch for a project. Unchanged
    # files are skipped by SyncService's content-identity check, so re-running
    # this is cheap and only rewrites drifted files.
    class FullSyncWorker
      include ApplicationWorker

      data_consistency :sticky
      sidekiq_options retry: 3
      feature_category :source_code_management
      urgency :low
      defer_on_database_health_signal :gitlab_main_org, %i[issues notes], 1.minute
      idempotent!
      # reschedule_once gives one follow-up run when an enqueue arrives
      # during execution -- note it only works for unscheduled enqueues
      # (perform_async, used by opt-in and lazy backfill); the cron's
      # staggered perform_in enqueues don't reschedule, which is fine since
      # the next nightly run is the catch-up.
      deduplicate :until_executed, if_deduplicated: :reschedule_once

      BATCH_SIZE = 100

      # purge_history replaces the branch before rebuilding, so content that
      # was already committed stops being reachable instead of merely being
      # deleted at the tip. The purge runs even when sync is disabled: a
      # disabled project keeps its branch as a frozen snapshot, and that
      # snapshot is exactly what has to go. Note that path returns before any
      # rebuild, which is the case that would be worst to get wrong -- peer
      # directories would be dropped with nothing to put them back.
      #
      # since (ISO8601) restricts the pass to records changed after it --
      # what ReconcileWorker sends nightly so the work is proportional to the
      # activity rather than to the size of the project. It arrives as a job
      # argument rather than being read from the branch here on purpose: this
      # worker stamps its own pass-start onto every commit it makes, so a run
      # that dies after its first batch would otherwise leave HEAD claiming a
      # window it never finished, and the retry would skip the remainder.
      #
      # rubocop: disable CodeReuse/ActiveRecord -- the query belongs to the sync and has no finder
      def perform(project_id, purge_history = false, since = nil)
        project = ::Project.find_by(id: project_id)
        return unless project

        # Captured before anything is read: a record changed mid-pass then
        # falls after the watermark and is picked up next time, rather than
        # slipping between the query and the commit.
        started_at = Time.current

        service = SyncService.new(project, synced_through: started_at)
        # Not delete_branch!: the branch also carries each peer's directory,
        # which no local record can rebuild. Only our own history is being
        # unpublished. See SyncService#purge_own_history!.
        service.purge_own_history! if purge_history

        return unless project.work_items_sync_enabled?

        # A missing branch means there is nothing to be incremental against,
        # whatever the caller asked for -- including a branch someone deleted
        # by hand.
        since = nil unless since.present? && project.repository.branch_exists?(SYNC_BRANCH)
        since &&= Time.zone.parse(since.to_s)

        sync_issuables(service, project, since)
        # Only on a full pass: label, milestone and group changes are embedded
        # in every file that references them, and ReconcileWorker forces an
        # unfiltered pass whenever any of them moved.
        service.execute_catalogs unless since
        # Always: a deleted record moves no timestamp, so orphan collection is
        # its only backstop and it is cheap.
        service.remove_orphans

        # Only once everything above succeeded. Lets both cron jobs decide
        # whether this project is worth looking at without reading its branch.
        project.record_work_items_sync!(started_at, unfiltered: since.nil?)
      rescue ::Gitlab::Git::PreReceiveError => e
        ::Gitlab::AppLogger.warn(
          message: 'work items full sync rejected by pre-receive check',
          project_id: project_id, error: e.message)
      end

      private

      def sync_issuables(service, project, since)
        issues = since ? project.issues.where('issues.updated_at > ?', since) : project.issues
        merge_requests = if since
                           project.merge_requests.where('merge_requests.updated_at > ?', since)
                         else
                           project.merge_requests
                         end

        issues.each_batch(of: BATCH_SIZE) { |batch| service.execute(batch) }
        merge_requests.each_batch(of: BATCH_SIZE) { |batch| service.execute(batch) }

        # Commit notes are grouped by sha rather than by row, so the batching
        # unit is the distinct sha. A commit note has no issuable to touch, so
        # its own updated_at is the only timestamp there is to filter on.
        notes = project.commit_notes
        notes = notes.where('notes.updated_at > ?', since) if since
        notes.distinct.pluck(:commit_id).each_slice(BATCH_SIZE) do |shas|
          service.execute_commit_notes(shas)
        end
      end
      # rubocop: enable CodeReuse/ActiveRecord
    end
  end
end
