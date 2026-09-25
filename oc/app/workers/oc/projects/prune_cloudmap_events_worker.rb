# frozen_string_literal: true

module OC
  module Projects
    # OC Change -- keeps oc_cloudmap_events bounded.
    #
    # Age rather than a consumer's cursor. Pruning below the last acknowledged
    # cursor would hold rows exactly as long as they are needed, but it needs
    # consumers to report progress, and one that stops reporting pins the
    # table for ever. An age cutoff needs nothing from anybody, and when it is
    # wrong the consequence is a reconciling crawl rather than lost data.
    #
    # So RETENTION is really an outage budget: how long the cloudmap sync can
    # be down before it must fall back to that crawl.
    class PruneCloudmapEventsWorker
      include ApplicationWorker
      include CronjobQueue # rubocop:disable Scalability/CronWorkerContext -- prunes the whole table

      data_consistency :sticky
      feature_category :source_code_management
      defer_on_database_health_signal :gitlab_main_org, %i[oc_cloudmap_events], 1.minute

      RETENTION = 30.days
      # Capped rather than looped to completion, as upstream's
      # PruneOldEventsWorker is: a run that finds more than this leaves the
      # rest for the next one instead of holding a long transaction.
      DELETE_LIMIT = 10_000

      def perform
        deleted = ::OC::Projects::CloudmapEvent
          .occurred_before(RETENTION.ago)
          .delete_with_limit(DELETE_LIMIT)

        log_extra_metadata_on_done(:deleted_rows, deleted)
      end
    end
  end
end
