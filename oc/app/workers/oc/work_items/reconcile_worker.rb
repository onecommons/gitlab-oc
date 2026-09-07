# frozen_string_literal: true

module OC
  module WorkItems
    # Nightly cron: enqueues a FullSyncWorker for every sync-enabled project
    # that may have drifted since its last sync commit. FullSyncWorker only
    # commits actual drift (byte-identical files are skipped) and garbage
    # collects orphaned files, so this converges each project's sync branch
    # with the database.
    class ReconcileWorker
      include ApplicationWorker

      data_consistency :sticky
      idempotent!

      include CronjobQueue # rubocop:disable Scalability/CronWorkerContext -- the job sets context per project inside perform

      feature_category :source_code_management

      # Stagger full syncs so a large instance doesn't hit Gitaly all at once.
      ENQUEUE_INTERVAL = 2.seconds

      # rubocop: disable CodeReuse/ActiveRecord -- the query belongs to the sync and has no finder
      def perform
        enqueued = 0
        seen = Set.new

        OC::WorkItems.sync_candidates.find_each do |attribute|
          next unless seen.add?(attribute.project_id)

          project = ::Project.find_by(id: attribute.project_id)
          next unless project&.work_items_sync_enabled?
          # Before any Gitaly call: on an instance where most projects are
          # dormant, reading each branch to discover nothing had changed was
          # the bulk of this job's cost.
          next unless needs_reconcile?(project)

          commit = project.repository.commit(SYNC_BRANCH)

          FullSyncWorker.perform_in(
            enqueued * ENQUEUE_INTERVAL, project.id, false, window_for(project, commit))
          enqueued += 1
        end

        log_extra_metadata_on_done(:enqueued_full_syncs, enqueued)
        log_extra_metadata_on_done(:enqueued_imports, enqueue_imports)
      end

      private

      # The backstop for the import side: one job per project that already
      # holds replicas. ImportRefreshWorker narrows it again to the peers that
      # project has already imported, and says there why the nightly is bounded
      # this way rather than authorized like a push.
      #
      def enqueue_imports
        OC::WorkItems::ReplicatedWorkItem.distinct.pluck(:project_id).each_with_index do |project_id, index|
          ImportRefreshWorker.perform_in(index * ENQUEUE_INTERVAL, project_id)
        end.size
      end

      # Skip projects with nothing newer than the last pass. Labels and
      # milestones count because their edits (e.g. renames) are embedded in the
      # YAML but do not touch the issuables' updated_at.
      #
      # Compared against the recorded pass time rather than the sync commit's
      # date, so a project that cannot have changed is dismissed on indexed
      # aggregates alone. A missing marker means never synced -- including
      # every project that predates it, which each get one pass and then
      # settle.
      #
      # Blind spots, both accepted: deletions move no updated_at, so an orphan
      # file left by a missed deletion won't wake the reconcile by itself; and
      # a branch deleted by hand is no longer noticed here, since nothing is
      # read from the repository. Both are cleaned up when anything else in the
      # project changes, or by an explicit FullSyncWorker.
      def needs_reconcile?(project)
        content_change = content_change_at(project)
        return false unless content_change # nothing syncable exists

        synced_at = project.work_items_synced_at
        return true unless synced_at

        # project.updated_at joins the comparison only once content exists:
        # visibility flips change the confidential filtering policy, and
        # renames/transfers change every embedded web_url.
        [content_change, project.updated_at].max > synced_at
      end

      # How much of the project the full sync should look at, as an ISO8601
      # string or nil for everything.
      #
      # Scoped is the normal case, and it is what keeps the nightly run
      # proportional to the day's activity rather than to the project's size.
      # It is only safe when issues and merge requests are the only things that
      # moved: a label rename, a milestone edit, a project rename or a
      # visibility change are each embedded in, or filter, every file, and none
      # of them touches the records they affect.
      def window_for(project, commit)
        watermark = commit && OC::WorkItems.synced_through(commit.message)
        return unless watermark

        ambient = ambient_change_at(project)
        return if ambient && ambient > watermark

        watermark.utc.iso8601
      end

      # Everything a serialized file depends on that is not the record itself:
      # the labels and milestones it embeds a copy of, and the project whose
      # path every web_url is built from and whose visibility decides the
      # confidential filtering. None of these touches the records they affect.
      def ambient_change_at(project)
        [
          OC::WorkItems.labels_for(project).maximum(:updated_at),
          OC::WorkItems.milestones_for(project).maximum(:updated_at),
          project.updated_at
        ].compact.max
      end

      def content_change_at(project)
        [
          project.issues.maximum(:updated_at),
          project.merge_requests.maximum(:updated_at),
          # Commit notes have no issuable to touch, so nothing else here moves
          # when one changes -- and a project whose only synced content is
          # commit notes would otherwise never look reconcilable at all.
          project.commit_notes.maximum(:updated_at),
          OC::WorkItems.labels_for(project).maximum(:updated_at),
          OC::WorkItems.milestones_for(project).maximum(:updated_at)
        ].compact.max
      end
      # rubocop: enable CodeReuse/ActiveRecord
    end
  end
end
