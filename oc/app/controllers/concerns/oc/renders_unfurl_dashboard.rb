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

    # unfurl_type_without_recording rather than unfurl_dashboard?: classifying
    # writes, and these all run on GET. It still answers for a project the
    # classifier has not reached, which a freshly pushed dashboard is.
    def unfurl_dashboard_project?
      request.format.html? && project&.unfurl_type_without_recording == ::OC::UNFURL_DASHBOARD
    end

    def render_unfurl_dashboard
      @readme_contents = unfurl_dashboard_readme

      # oc-pages' share-resource-toggle reads this off gon, not off the mount
      # point's dataset. Set here rather than in add_gon_variables so an
      # instance CI variable is not handed to every page on the instance.
      gon.openCloudPublish = open_cloud_publish_request

      # Every dashboard view is one page as far as the bundler is concerned,
      # whichever controller and action rendered it. _head.html.haml passes
      # this to webpack_controller_bundle_tags.
      @js_action_name = 'oc_dashboard'

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
