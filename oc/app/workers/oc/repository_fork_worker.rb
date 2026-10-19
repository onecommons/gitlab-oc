# frozen_string_literal: true

module OC
  module RepositoryForkWorker
    extend ::Gitlab::Utils::Override

    private

    override :fork_repository
    def fork_repository(target_project, source_project)
      super

      remove_work_items_sync_branch(target_project)
    end

    # A fork copies every branch, including the parent's gitlab-work-items
    # branch -- but issues/MRs live in the database and are NOT forked, so
    # the inherited branch describes another project's work items (and, for
    # a private parent, can expose confidential issues to fork members).
    # Drop it: the deleted ref makes the parent's sync commits unreachable,
    # and the fork's own branch is rebuilt lazily on its first change.
    def remove_work_items_sync_branch(target_project)
      repository = target_project.repository
      return unless repository.branch_exists?(OC::WorkItems::SYNC_BRANCH)

      repository.delete_refs("refs/heads/#{OC::WorkItems::SYNC_BRANCH}")
      repository.expire_branches_cache
    rescue StandardError => e
      # Never fail the fork over cleanup; the reconcile cron cannot heal
      # this (the fork's own issues would not match), so log loudly.
      ::Gitlab::AppLogger.error(
        message: 'failed to remove inherited work items sync branch from fork',
        project_id: target_project.id, ::Labkit::Fields::ERROR_MESSAGE => e.message)
    end
  end
end
