# frozen_string_literal: true

module OC
  # A dashboard project shows the oc-pages dashboard app wherever its own pages
  # would otherwise render: the project itself, its environments, its
  # deployments.
  module RendersUnfurlDashboard
    extend ActiveSupport::Concern

    included do
      helper_method :open_cloud_publish_request, :unfurl_environment_variables_data
    end

    private

    # A request whose Accept is a bare */* negotiates to Mime::ALL, which
    # respond_to still serves from its format.html block. Mime#html? is false
    # for it, and so is Mime#all? -- that type carries no symbol.
    def html_page_request?
      request.format.html? || request.format == Mime::ALL
    end

    # unfurl_type_without_recording rather than unfurl_dashboard?: classifying
    # writes, and these all run on GET. It still answers for a project the
    # classifier has not reached, which a freshly pushed dashboard is.
    def unfurl_dashboard_project?
      html_page_request? && project&.unfurl_type_without_recording == ::OC::UNFURL_DASHBOARD
    end

    def render_unfurl_dashboard
      @readme_contents = unfurl_rendered_readme

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

    # What the dashboard's environment page reads off #js-oc-ci-variables: the
    # variables endpoint, and the cloud account the environment deploys into.
    #
    # The CLOUDSDK fallback is for the service-account-key method, which writes
    # environment-scoped variables and no provider row, as it did in 15.11.
    def unfurl_environment_variables_data
      return {} unless @environment

      provider = @environment.unfurl_provider

      {
        endpoint: project_variables_path(project),
        project_id: project.id,
        maskable_regex: helpers.ci_variable_maskable_regex,
        environment_name: @environment.name,
        primary_provider_gcp_project_id: provider&.gcp_project || scoped_variable('CLOUDSDK_CORE_PROJECT'),
        primary_provider_gcp_zone: provider&.zone || scoped_variable('CLOUDSDK_COMPUTE_ZONE'),
        primary_provider_aws_default_region: provider&.region,
        primary_provider_aws_role_arn: provider&.role_arn
      }
    end

    def scoped_variable(key)
      project.variables.find do |variable|
        variable.key == key && variable.environment_scope == @environment.name
      end&.value
    end

    # Rendered through GitLab's own pipeline rather than by calling
    # gitlab-markup directly, which the fork did until 19.3. That worked: the
    # gem carried a markdown handler up to 1.9, which 15.11 pins. 2.1 dropped
    # it -- GitLab renders markdown through Banzai -- so the same call started
    # returning a .md readme unchanged, and since this value goes to v-html an
    # unrendered readme was an unsanitised one.
    def unfurl_rendered_readme
      readme = project.repository&.tree&.readme
      return unless readme

      ::Markup::RenderingService.new(
        readme.data,
        file_name: readme.name,
        context: { project: project, text_source: :blob, requested_path: readme.path },
        postprocess_context: { current_user: current_user, ref: project.default_branch,
                               requested_path: readme.path }
      ).execute
    end

    def open_cloud_publish_request
      ::Ci::InstanceVariable.all_cached.find { |variable| variable.key == 'UNFURL_OPEN_CLOUD_PUBLISH_REQUEST' }&.value
    end
  end
end
