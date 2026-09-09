# frozen_string_literal: true

# OC Change -- user-initiated atomic deployments from the dashboard.
# Upstream's deployments controller is nested under an environment and only
# reads, so the dashboard's trigger gets its own project-level endpoint.
module Projects
  class UnfurlDeploymentsController < Projects::ApplicationController
    before_action :authorize_create_pipeline!

    feature_category :continuous_delivery
    urgency :low

    def create
      return render json: { message: '404 project not found' }, status: :not_found unless
        project.unfurl_dashboard?

      token_results = deployment_params[:project_dependencies].to_h.map do |project_path, variable_name|
        setup_deploy_token(project_path, variable_name)
      end

      unless token_results.all? { |result| result[:status] == :success }
        return render json: { message: 'failed to create tokens', errors: token_results }, status: :bad_request
      end

      render_pipeline(
        ::Ci::CreatePipelineService
          .new(project, project_bot_user, pipeline_params)
          .execute(:web, ignore_skip_ci: true, save_on_errors: false)
      )
    end

    private

    def authorize_create_pipeline!
      access_denied! unless can?(current_user, :create_pipeline, project)
    end

    def render_pipeline(service_response)
      pipeline = service_response.payload

      if service_response.success?
        render json: PipelineSerializer.new(project: project, current_user: current_user).represent(pipeline),
          status: :created
      else
        render json: {
          errors: pipeline.error_messages.map(&:content),
          warnings: pipeline.warning_messages(limit: ::Gitlab::Ci::Warnings::MAX_LIMIT).map(&:content),
          total_warnings: pipeline.warning_messages.length
        }, status: :bad_request
      end
    end

    # A deployment pulls in the repositories and images of the projects it
    # depends on, so each one needs a deploy token exposed as a CI variable.
    # rubocop: disable CodeReuse/ActiveRecord -- token and variable lookups the finders do not offer
    def setup_deploy_token(project_path, variable_name)
      upstream = ::Project.find_by_full_path(project_path)
      return failure(project_path, '404 upstream project not found', :not_found) unless upstream
      return { status: :success, project: project_path, deploy_token: :public } if upstream.public?

      unless can?(current_user, :read_code, upstream) && can?(current_user, :read_container_image, upstream)
        return failure(project_path, "cannot create deploy token on #{upstream.full_path}")
      end

      token_params = deploy_token_params
      token = upstream.deploy_tokens.find_by(username: token_params[:username])&.token
      existing_variable = project.variables.find_by(key: variable_name)
      return { status: :success, project: project_path, deploy_token: token } if
        token && existing_variable&.value == token

      unless token
        result = ::Projects::DeployTokens::CreateService.new(upstream, current_user, token_params).execute
        return result.merge(project: project_path) unless result[:status] == :success

        token = result[:deploy_token].token
      end

      store_deploy_token(project_path, variable_name, token, existing_variable)
    end
    # rubocop: enable CodeReuse/ActiveRecord

    def store_deploy_token(project_path, variable_name, token, existing_variable)
      variable_params = { variable_type: :env_var, key: variable_name, value: token, masked: true }

      change_params =
        if existing_variable
          { action: :update, variable: existing_variable, variable_params: variable_params }
        else
          { action: :create, variable_params: variable_params }
        end

      variable = ::Ci::ChangeVariableService.new(
        container: project, current_user: current_user, params: change_params
      ).execute

      return failure(project_path, "cannot save deploy token to variable #{variable_name}") unless
        variable&.persisted?

      { status: :success, project: project_path, deploy_token: token }
    end

    def failure(project_path, message, status = :error)
      { status: status, project: project_path, message: message }
    end

    def deploy_token_params
      {
        name: "Unfurl token for #{project.full_path}",
        username: "UNFURL_DEPLOY_TOKEN_#{project.id}",
        expires_at: '',
        read_repository: '1',
        read_registry: '1',
        write_registry: '0',
        read_package_registry: '1',
        write_package_registry: '0'
      }
    end

    def deployment_params
      params.require(:deployment).permit(:bot_id, :schedule, project_dependencies: {})
    end

    # The dashboard asks for a delay in words; the job reads it back through
    # $START_IN, which Ci::Build expands before scheduling.
    def pipeline_params
      schedule = deployment_params[:schedule]
      schedule = '0 seconds' if schedule == 'now'

      { ref: permitted_pipeline_params[:ref],
        variables_attributes: pipeline_variables +
          [{ key: 'START_IN', variable_type: :env_var, value: schedule }] }
    end

    def permitted_pipeline_params
      params.require(:pipeline).permit(:ref, variables_attributes: %i[key variable_type value secret_value])
    end

    # oc-pages still sends 19.3's `value` under its old name.
    def pipeline_variables
      permitted_pipeline_params.to_h.fetch('variables_attributes', []).map do |attributes|
        attributes = attributes.symbolize_keys
        { key: attributes[:key],
          variable_type: attributes[:variable_type] || :env_var,
          value: attributes[:value] || attributes[:secret_value] }
      end
    end

    def project_bot_user
      ::User.find_by_id(deployment_params[:bot_id])
    end
  end
end
