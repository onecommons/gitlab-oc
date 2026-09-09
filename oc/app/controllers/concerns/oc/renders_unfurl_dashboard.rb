# frozen_string_literal: true

module OC
  # A dashboard project shows the oc-pages dashboard app wherever its own pages
  # would otherwise render: the project itself, its environments, its
  # deployments.
  module RendersUnfurlDashboard
    extend ActiveSupport::Concern

    included do
      helper_method :open_cloud_publish_request
    end

    private

    # recorded_unfurl_type rather than unfurl_dashboard?: classifying writes,
    # and these all run on GET.
    def unfurl_dashboard_project?
      request.format.html? && project&.recorded_unfurl_type == ::OC::UNFURL_DASHBOARD
    end

    def render_unfurl_dashboard
      @readme_contents = unfurl_dashboard_readme

      render 'projects/dashboard'
    end

    def unfurl_dashboard_readme
      readme = project.repository&.tree&.readme
      return unless readme

      ::GitHub::Markup.render(readme.name, readme.data)
    end

    def open_cloud_publish_request
      ::Ci::InstanceVariable.all_cached.find { |variable| variable.key == 'UNFURL_OPEN_CLOUD_PUBLISH_REQUEST' }&.value
    end
  end
end
