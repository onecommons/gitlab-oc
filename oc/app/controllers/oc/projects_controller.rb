# frozen_string_literal: true

module OC
  module ProjectsController
    extend ActiveSupport::Concern
    extend ::Gitlab::Utils::Override

    prepended do
      include ::OC::RendersUnfurlDashboard

      skip_before_action :authenticate_user!, only: :overview
    end

    # A dashboard project is the oc-pages dashboard app, not a repository page.
    override :show
    def show
      return super unless unfurl_dashboard_project?

      return redirect_to project_import_path(@project, custom_import_params) if @project.import_in_progress?

      @project = @project.present(current_user: current_user)

      render_unfurl_dashboard
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

    private

    # A group CI variable named after the project holds the URL of its live deployment.
    def live_preview_url
      key = "__UNFURL_CLOUD_URL_#{project.full_path.gsub('/', '__').tr('-', '_')}"

      project.group&.variables&.find { |variable| variable.key == key }&.value
    end
  end
end
