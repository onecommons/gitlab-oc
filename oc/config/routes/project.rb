# frozen_string_literal: true

constraints(Projects::ProjectUrlConstraint.new) do
  scope(
    path: '*namespace_id',
    as: :namespace,
    namespace_id: Gitlab::PathRegex.full_namespace_route_regex
  ) do
    scope(
      path: ':project_id',
      constraints: { project_id: Gitlab::PathRegex.project_route_regex },
      module: :projects,
      as: :project
    ) do
      scope '-' do
        get 'overview(/*vueroute)', to: '/projects#overview', as: :overview

        # The dashboard app's deployments view. Upstream has no project-level
        # deployments route: its controller is nested under an environment and
        # answers with JSON.
        get 'deployments(/*vueroute)', to: '/projects#deployments', as: :unfurl_deployments
        resource :work_items_sync, only: [:update], controller: :work_items_sync
      end
    end
  end
end
