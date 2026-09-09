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

        # The dashboard app's own views. Upstream routes neither at project
        # level: its deployments controller is nested under an environment and
        # answers with JSON, and it has no applications concept at all.
        get 'deployments(/*vueroute)', to: '/projects#deployments', as: :unfurl_deployments
        # The dashboard's deploy button. Named 'new' by the client, but it
        # creates: it mints deploy tokens and triggers the pipeline.
        post 'deployments/new', to: 'unfurl_deployments#create', as: :trigger_unfurl_deployment
        get 'applications(/*vueroute)', to: '/projects#applications', as: :unfurl_applications
        # Operator repair for a project whose Unfurl caches have gone stale.
        get 'invalidate_cache', to: '/projects#invalidate_cache'

        # The projects a dashboard deploys from. Upstream's own subscriptions
        # routes are EE, so nothing is shadowed here.
        resource :subscriptions, only: [:show, :create, :destroy]

        resource :work_items_sync, only: [:update], controller: :work_items_sync
      end
    end
  end
end
