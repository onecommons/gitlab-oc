# frozen_string_literal: true

module OC
  module ProjectsController
    extend ActiveSupport::Concern
    extend ::Gitlab::Utils::Override

    prepended do
      skip_before_action :authenticate_user!, only: :overview

      helper_method :open_cloud_publish_request
    end

    # A dashboard project is the oc-pages dashboard app, not a repository page.
    override :show
    def show
      return super unless dashboard_project?

      return redirect_to project_import_path(@project, custom_import_params) if @project.import_in_progress?

      @project = @project.present(current_user: current_user)
      @readme_contents = rendered_readme

      render 'projects/dashboard'
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

    # recorded_unfurl_type rather than unfurl_dashboard?: classifying writes,
    # and this runs on every project GET.
    def dashboard_project?
      request.format.html? && project.recorded_unfurl_type == ::OC::UNFURL_DASHBOARD
    end

    def open_cloud_publish_request
      ::Ci::InstanceVariable.all_cached.find { |v| v.key == 'UNFURL_OPEN_CLOUD_PUBLISH_REQUEST' }&.value
    end

    def rendered_readme
      readme = project.repository&.tree&.readme
      return unless readme

      ::GitHub::Markup.render(readme.name, readme.data)
    end

    # A group CI variable named after the project holds the URL of its live deployment.
    def live_preview_url
      key = "__UNFURL_CLOUD_URL_#{project.full_path.gsub('/', '__').tr('-', '_')}"

      project.group&.variables&.find { |variable| variable.key == key }&.value
    end
  end
end
