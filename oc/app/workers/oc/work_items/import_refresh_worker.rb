# frozen_string_literal: true

module OC
  module WorkItems
    # The nightly catch-up on the import side, enqueued per project by
    # ReconcileWorker.
    #
    # A push triggers its own import, so this is here for the runs that did not
    # happen: a worker that died, a job lost to a restart, a push that was
    # refused because the pusher was not an Owner and later became one, a push
    # nobody was identified for. It also re-examines deferred merge requests,
    # whose source files will never change to announce that their commits
    # arrived -- the one thing here that is not a backstop.
    #
    # There is no pusher, so there is nobody to authorize against, and this is
    # bounded instead: only peers the project already holds replicas of. It
    # heals runs that failed or never happened; it never makes first contact.
    # Otherwise it would be a way around ImportWorker's Owner check -- push as
    # a Developer, be correctly refused, and have the cron do it hours later.
    #
    # That bound is the whole reason this is a worker of its own rather than an
    # argument to ImportWorker. Being unable to name a pusher is not permission
    # to skip checking for one.
    #
    # For the same reason it never starts a transfer, only finishes one already
    # under way. The bound authorizes replicating a peer we already replicate;
    # it says nothing about accepting an item from them or handing one over,
    # and rows from ordinary replication exist either way. A demote is
    # different and does happen here: it needs a row that only an authorized
    # run can have written.
    class ImportRefreshWorker
      include ApplicationWorker

      data_consistency :sticky
      sidekiq_options retry: 3
      feature_category :source_code_management
      urgency :low
      defer_on_database_health_signal :gitlab_main_org, %i[issues notes], 1.minute
      idempotent!
      # As on ImportWorker: the run reads the branch as it is when it starts,
      # so a push arriving mid-run is caught by the next run rather than lost.
      deduplicate :until_executing, including_scheduled: true

      # rubocop: disable CodeReuse/ActiveRecord -- the query belongs to the sync and has no finder
      def perform(project_id)
        project = ::Project.find_by(id: project_id)
        return unless project
        return if project.work_items_sync_opted_out?

        ImportRunService.new(project).execute(directories: imported_directories(project))
      end

      private

      # Read here rather than passed in the job arguments: the peers that
      # matter are the ones on record when the run happens, not when
      # ReconcileWorker walked the instance some seconds or minutes earlier.
      #
      # An empty list is a real answer -- the project's last replica was
      # deleted -- and it means the run does nothing, which is right. Making
      # first contact is a push's job.
      def imported_directories(project)
        OC::WorkItems::ReplicatedWorkItem
          .where(project_id: project.id)
          .distinct
          .pluck(:source_instance_uuid)
      end
      # rubocop: enable CodeReuse/ActiveRecord
    end
  end
end
