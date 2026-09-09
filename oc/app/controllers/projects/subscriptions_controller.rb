# frozen_string_literal: true

# OC Change -- a dashboard's record of the projects it deploys from.
# Upstream's subscriptions controller is EE and never loads in this edition.
module Projects
  class SubscriptionsController < Projects::ApplicationController
    before_action :ensure_dashboard!
    before_action :authorize_maintainer!

    before_action :upstream_project, only: [:create, :destroy]
    before_action :authorize_upstream!, only: [:create, :destroy]

    feature_category :continuous_integration
    urgency :low

    # JSON only: the dashboard app is the only reader, and there has never been
    # a page for this.
    def show
      respond_to do |format|
        format.json do
          render json: project.upstream_projects.map { |upstream| ProjectSerializer.new.represent(upstream) }
        end
      end
    end

    def create
      existing = upstream_project_link
      return respond_with(:ok, _('Upstream project already linked.'), json: existing) if existing

      link = project.upstream_project_subscriptions.create(upstream_project: upstream_project)

      if link.persisted?
        respond_with(:created, _('Upstream project linked successfully.'), json: link)
      else
        respond_with(:unprocessable_entity, _('Failed to link upstream project'), json: link.errors)
      end
    end

    def destroy
      if upstream_project_link&.destroy
        respond_with(:ok, _('Upstream project removed successfully.'))
      else
        respond_with(:unprocessable_entity, _('Failed to remove upstream project'))
      end
    end

    private

    def respond_with(status, notice, json: nil)
      respond_to do |format|
        format.html { redirect_to project_path(project), status: :found, notice: notice }
        format.json do
          if json.nil?
            head status
          else
            render json: json, status: status
          end
        end
      end
    end

    # Subscriptions mean nothing on a project that is not a dashboard.
    def ensure_dashboard!
      not_found unless project.unfurl_dashboard?
    end

    # A message rather than the bare helper, so a member who can already see
    # the project is told why instead of being shown a 404.
    # rubocop: disable Gitlab/Authz/PermissionCheck -- no granular permission covers a fork-owned dashboard setting
    def authorize_maintainer!
      return if can?(current_user, :admin_project, project)

      access_denied!(_('You must be a project maintainer.'))
    end
    # rubocop: enable Gitlab/Authz/PermissionCheck

    # Subscribing pulls the upstream's images into a deployment, so reading
    # them is the access this asks for.
    def authorize_upstream!
      return if upstream_project && can?(current_user, :read_container_image, upstream_project)

      access_denied!(_('You are not authorized to read the upstream project.'))
    end

    def upstream_project
      @upstream_project ||= ::Project.find_by_full_path(params.permit(:upstream)[:upstream])
    end

    # rubocop: disable CodeReuse/ActiveRecord -- the join row itself, which no finder offers
    def upstream_project_link
      project.upstream_project_subscriptions.find_by(upstream_project: upstream_project)
    end
    # rubocop: enable CodeReuse/ActiveRecord
  end
end
