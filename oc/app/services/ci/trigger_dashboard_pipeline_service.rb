# frozen_string_literal: true

# OC Change -- redeploy every dashboard subscribed to this project.
module Ci
  class TriggerDashboardPipelineService < BaseProjectService
    include ::Services::ReturnServiceResponses

    def execute(_pipeline, variables = {})
      responses = project.downstream_project_subscriptions.filter_map do |link|
        dispatch(link, variables)
      end

      errors = responses.select { |response| response[:status] == :error }

      if errors.present?
        error('Could not create pipelines', errors.first[:http_status], pipelines: responses)
      else
        success(pipelines: responses)
      end
    end

    private

    def dispatch(link, variables)
      downstream = link.downstream_project
      # A dashboard without a bot falls back to whoever triggered upstream.
      # That grants nothing: the pipeline chain still authorizes them, so an
      # outsider fails the create rather than running as the dashboard.
      author = project_bot_for(downstream) || current_user

      unless author
        ::Gitlab::AppLogger.info(
          message: 'Skipping dashboard redeploy: no bot member and no triggering user',
          project_id: downstream.id, subscription_id: link.id
        )
        return
      end

      pipeline_service_response(
        ::Ci::CreatePipelineService
          .new(downstream, author, ref: downstream.default_branch,
            variables_attributes: variables_attributes(variables.merge(UPSTREAM_SUBSCRIPTION_ID: link.id)))
          .execute(:pipeline, ignore_skip_ci: true)
          .payload
      )
    end

    def variables_attributes(variables)
      variables.map { |key, value| { key: key.to_s, value: value.to_s } }
    end

    # Bots are always direct members of the project, so this looks no further.
    def project_bot_for(downstream)
      downstream.members.find { |member| member.user&.bot? }&.user
    end

    # Copied from app/services/ci/pipeline_trigger_service.rb
    def pipeline_service_response(pipeline)
      if pipeline.created_successfully?
        success(pipeline: pipeline)
      elsif pipeline.persisted?
        error(
          pipeline.errors.messages.presence || pipeline.failure_reason.presence || 'Could not create pipeline',
          :unprocessable_entity
        )
      else
        error(pipeline.errors.messages, :bad_request)
      end
    end
  end
end
