# frozen_string_literal: true

module OC
  module ProjectCacheWorker
    extend ::Gitlab::Utils::Override

    # Classification reads the repository's cached Unfurl files, which super
    # has just refreshed. Nothing else recomputes it, so a project stays
    # invisible to blueprint and dashboard discovery until this runs.
    override :perform
    def perform(project_id, files = [], statistics = [], refresh_statistics = true)
      super

      project = ::Project.find_by_id(project_id)
      return unless project&.repository&.exists?

      skip_writes_if_replica(project) { project.refresh_unfurl_type! }
    end
  end
end
