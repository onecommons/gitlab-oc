# frozen_string_literal: true

module OC
  module ProjectsController
    extend ActiveSupport::Concern
    extend ::Gitlab::Utils::Override

    # The badge renders one of these four directories of SVG templates. Anything
    # else is the default, rather than a render of an attacker-chosen path.
    BADGE_TYPES = %w[default white monochrome mono_inverse].freeze

    prepended do
      include ::OC::RendersUnfurlDashboard

      feature_category :groups_and_projects, [:overview]
      feature_category :continuous_delivery, [:deployments, :applications]
      feature_category :source_code_management, [:invalidate_cache]
      feature_category :continuous_delivery, [:deploy_status_as_image]

      skip_before_action :authenticate_user!, only: [:overview, :deploy_status_as_image]

      # The badge is embedded on pages outside this instance and answers for a
      # project named in the path, so it looks the project up itself rather
      # than through the before_actions -- which is also what keeps 15.11's
      # three in-place edits to ProjectsController's `except:` lists out of
      # this port.
      skip_before_action :project, only: :deploy_status_as_image
      skip_before_action :repository, only: :deploy_status_as_image

      # invalidate_cache is a GET that writes, so an operator can repair a
      # project by visiting a URL. Restricting it to those who could clear
      # these caches by other means keeps that convenience from being
      # something a stray link can trigger.
      before_action :authorize_admin_project!, only: :invalidate_cache
    end

    # OC Change #88 #1256 -- a public "deploy with Unfurl Cloud" badge, as an
    # SVG for a README or an HTML document for an iframe.
    def deploy_status_as_image
      badge = params.permit(:namespace_id, :project_id, :type, :cloud, :count)

      @project = ::Project.find_by_full_path(File.join(badge[:namespace_id], badge[:project_id]))
      return head :not_found unless @project&.public?

      @type = badge[:type].presence_in(BADGE_TYPES) || 'default'
      @template_flags = badge.slice(:cloud, :count).to_h
      @deployment_count = @project.blueprint_deployment_count

      respond_to do |format|
        format.svg do
          @template = @template_flags.keys.join('-').presence || 'default'

          render template: 'projects/deploy_status_as_image', formats: [:svg], layout: nil
        end
        format.html { render template: 'projects/deploy_status_as_image', layout: nil }
      end
    end

    # A dashboard project is the oc-pages dashboard app, not a repository page.
    override :show
    def show
      return super unless unfurl_dashboard_project?

      return redirect_to project_import_path(@project, custom_import_params) if @project.import_in_progress?

      @project = @project.present(current_user: current_user)

      render_unfurl_dashboard
    end

    # The dashboard app's own views, which only a dashboard has. Both are
    # client-side routes the server has to answer so a reload lands on them.
    def deployments
      render_dashboard_section
    end

    def applications
      render_dashboard_section
    end

    # The Unfurl Cloud blueprint page, a Vue app from the oc-pages package.
    def overview
      @id = @ref = repository_root
      @path = ''
      @ref_type = 'heads'
      @project = @project.present(current_user: current_user)
      @live_preview_url = live_preview_url

      render 'projects/overview'
    end

    # Forgets everything cached about a project's Unfurl files: the repository
    # method caches, the recorded classification, and the Unfurl server's own
    # copy. The repair for a project whose caches disagree with its files.
    def invalidate_cache
      project.repository.expire_unfurl_caches
      project.refresh_unfurl_type!

      cleared = clear_unfurl_server_cache
      flash[:alert] = _('Failed to clear the Unfurl server cache.') if cleared == false
      flash[:notice] = _('No Unfurl server is configured.') if cleared.nil?

      respond_to do |format|
        format.html { redirect_to project_path(project) }
        format.json { render json: { cleared: cleared } }
      end
    end

    private

    def clear_unfurl_server_cache
      url = ::OC::Repositories::UnfurlServer.internal_url
      # nil rather than true: an operator repairing a project should not be
      # told a cache was cleared on a server nothing was sent to.
      return if url.blank?

      ::Gitlab::HTTP.post(
        "#{url}/clear_project_file_cache",
        query: { auth_project: project.path_with_namespace },
        allow_local_requests: true
      )

      true
    rescue *::Gitlab::HTTP::HTTP_ERRORS
      false
    end

    def render_dashboard_section
      return render_404 unless unfurl_dashboard_project?

      @project = @project.present(current_user: current_user)

      render_unfurl_dashboard
    end

    # A group CI variable named after the project holds the URL of its live deployment.
    def live_preview_url
      key = "__UNFURL_CLOUD_URL_#{project.full_path.gsub('/', '__').tr('-', '_')}"

      project.group&.variables&.find { |variable| variable.key == key }&.value
    end
  end
end
