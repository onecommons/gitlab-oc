# frozen_string_literal: true

module OC
  module WorkItems
    # Imports whatever a peer's directories on the sync branch now say, on
    # behalf of whoever pushed them.
    #
    # This is the authorized entry point, and the only one that may touch every
    # peer directory on the branch -- which is safe only because someone who
    # may delete this project's issues put them there. So it needs a pusher,
    # and no pusher means no import.
    #
    # The nightly catch-up has no pusher and cannot use this entry point. It is
    # ImportRefreshWorker, which is bounded rather than authorized. There are
    # two workers precisely so that the trusted path is chosen by the caller
    # rather than fallen into: when one worker served both, the unauthorized
    # path was selected by the *absence* of a user id, so any caller that
    # passed a nil one -- BranchHooksService passes `current_user&.id` -- got
    # the widest scope there is without anyone deciding it should.
    class ImportWorker
      include ApplicationWorker

      data_consistency :sticky
      sidekiq_options retry: 3
      feature_category :source_code_management
      urgency :low
      defer_on_database_health_signal :gitlab_main_org, %i[issues notes], 1.minute
      idempotent!
      # The run reconciles against the branch as it is when it starts, so a
      # push arriving mid-run is picked up by the catch-up rather than lost --
      # which is what :until_executing gives, releasing the lock when execution
      # begins rather than when it ends.
      deduplicate :until_executing, including_scheduled: true

      # user_id keeps a default so that a job enqueued without one logs and
      # stops, rather than raising ArgumentError through three retries. It is
      # not a mode: there is no path below that proceeds without a user.
      #
      # rubocop: disable CodeReuse/ActiveRecord -- the query belongs to the sync and has no finder
      def perform(project_id, user_id = nil)
        project = ::Project.find_by(id: project_id)
        return unless project

        # A project that turned sync off is not opted back into it by someone
        # pushing a branch at it. ImportService refuses per document too; this
        # just avoids reading the branch at all.
        return if project.work_items_sync_opted_out?

        user = user_id && ::User.find_by(id: user_id)

        return unless allowed?(project, user)

        # The only entry point that may start a transfer, for the same reason
        # it is the only one that may touch every peer: an authorized pusher
        # moved the branch, and that is the authorization.
        ImportRunService.new(project).execute(directories: nil, initiate_transfers: true)
      end
      # rubocop: enable CodeReuse/ActiveRecord

      private

      # Skipped, not rejected. The push itself has already succeeded, and
      # failing it here would surface as a git error the pusher cannot act on
      # -- the branch is data, importing it is a privileged reading of that
      # data, and the two should not be confused.
      #
      # destroy_issue because that is where GitLab draws this line: an import
      # destroys and rebuilds issues, and only the roles allowed to delete one
      # (owner, planner) may bring a peer's in.
      #
      # No user is one of the skips, whether because nobody was identified for
      # the push or because whoever it was has since been deleted -- both
      # arrive here as nil and log as `user_id: null`. It means an import that
      # would have happened now waits for the nightly, which will only carry it
      # if the project already mirrors that peer.
      def allowed?(project, user)
        return true if user && Ability.allowed?(user, :destroy_issue, project)

        ::Gitlab::AppLogger.info(
          message: 'work items import skipped: push not authorized by an owner',
          project_id: project.id, ::Labkit::Fields::GL_USER_ID => user&.id)

        false
      end
    end
  end
end
