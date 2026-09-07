# frozen_string_literal: true

module OC
  module WorkItems
    # Weekly cron: rebuilds every sync-enabled project's branch from scratch,
    # unfiltered.
    #
    # ReconcileWorker runs nightly and only looks at records changed since the
    # last sync, which is what keeps it proportional to the day's activity
    # rather than to the size of the project. That leaves a residue it cannot
    # see, because the change moved no timestamp it can query:
    #
    #   * a deleted note -- Note has no after_destroy touch, and the row that
    #     would say which issue it was on is gone;
    #   * an award emoji added or removed, on an issuable or on a note;
    #   * anything written with update_column, or restored by an import;
    #   * a hand-edited or force-pushed branch.
    #
    # Each of those has a working incremental trigger, so this only matters
    # when that job died -- but nothing else would ever notice. This bounds
    # how long such a file can stay wrong to a week.
    #
    # Deliberately :throttled: it is pure background repair, and every project
    # it touches normally produces no commit at all.
    class SweepWorker
      include ApplicationWorker

      data_consistency :sticky
      idempotent!

      include CronjobQueue # rubocop:disable Scalability/CronWorkerContext -- the job sets context per project inside perform

      feature_category :source_code_management
      urgency :throttled

      # Wider than ReconcileWorker's: this enqueues unfiltered passes, which
      # are the expensive kind, and nothing about them is time-sensitive.
      ENQUEUE_INTERVAL = 10.seconds

      # rubocop: disable CodeReuse/ActiveRecord -- the query belongs to the sync and has no finder
      def perform
        enqueued = 0
        seen = Set.new

        OC::WorkItems.sync_candidates.find_each do |attribute|
          next unless seen.add?(attribute.project_id)

          project = ::Project.find_by(id: attribute.project_id)
          next unless project&.work_items_sync_enabled?
          next unless touched_since_last_sweep?(project)

          # No `since`: that is the whole point of this job.
          FullSyncWorker.perform_in(enqueued * ENQUEUE_INTERVAL, project.id)
          enqueued += 1
        end

        log_extra_metadata_on_done(:enqueued_full_syncs, enqueued)
      end

      private

      # A project gets one sweep after each spell of activity, rather than one
      # every week for the rest of its life. On an instance where most projects
      # are dormant, sweeping them all was re-serializing records nobody had
      # touched in a year, weekly, to commit nothing.
      #
      # last_activity_at is the signal because what this job exists to catch --
      # a deleted note, a toggled emoji -- needs somebody working in the
      # project, and that all but always writes an Event, which touches it
      # (throttled to hourly, which is far finer than weekly).
      #
      # "All but always" is the trade-off: deleting one old comment and leaving
      # writes no Event, so on a project that then falls silent that one file
      # stays wrong until something else happens there. Bounded, and the cost
      # of not doing this is a weekly full pass over every dead project.
      def touched_since_last_sweep?(project)
        swept_at = project.work_items_swept_at
        return true unless swept_at

        project.last_activity_at.present? && project.last_activity_at > swept_at
      end
      # rubocop: enable CodeReuse/ActiveRecord
    end
  end
end
