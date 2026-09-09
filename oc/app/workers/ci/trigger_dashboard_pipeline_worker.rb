# frozen_string_literal: true

# OC Change -- when CI passes on a project a dashboard deploys from, redeploy
# the dashboards subscribed to it.
module Ci
  class TriggerDashboardPipelineWorker
    include ::Gitlab::EventStore::Subscriber

    feature_category :pipeline_composition
    urgency :low
    defer_on_database_health_signal :gitlab_ci, %i[p_ci_pipelines p_ci_builds], 1.minute
    worker_resource_boundary :cpu

    # The dispatch has to see the pipeline that just finished, so this does not
    # read a replica.
    data_consistency :always

    def handle_event(event)
      pipeline = ::Ci::Pipeline.find_by_id_and_partition(event.data[:pipeline_id], event.data[:partition_id])
      return unless pipeline

      project = pipeline.project
      # A dashboard's own deployment pipeline must not start another one.
      # Reading what the classifier recorded, rather than classifying: this
      # runs for every successful pipeline on the instance.
      return if project.recorded_unfurl_type == ::OC::UNFURL_DASHBOARD

      ::Ci::TriggerDashboardPipelineService
        .new(project: project, current_user: pipeline.user)
        .execute(pipeline, upstream_variables(pipeline))
    end

    private

    # path_with_namespace is `user/repo`, not the full URL.
    def upstream_variables(pipeline)
      {
        UPSTREAM_PROJECT: pipeline.project.id.to_s,
        UPSTREAM_REPO: pipeline.project.path_with_namespace,
        UPSTREAM_REF: pipeline.source_ref,
        UPSTREAM_BRANCH: pipeline.source_ref,
        UPSTREAM_COMMIT: pipeline.sha,
        UPSTREAM_PIPELINE_ID: pipeline.id.to_s,
        UPSTREAM_PIPELINE: pipeline.id.to_s
      }
    end
  end
end
