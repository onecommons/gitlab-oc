# frozen_string_literal: true

# OC Change -- record that a blueprint was deployed, so a blueprint's deploy
# count is a lookup rather than a scan of every pipeline variable.
module Ci
  class RecordBlueprintDeploymentWorker
    include ::Gitlab::EventStore::Subscriber

    feature_category :continuous_delivery
    urgency :low
    worker_resource_boundary :cpu
    defer_on_database_health_signal :gitlab_main_org, %i[oc_blueprint_deployments], 1.minute
    data_consistency :delayed
    idempotent!

    def handle_event(event)
      pipeline = ::Ci::Pipeline.find_by_id_and_partition(event.data[:pipeline_id], event.data[:partition_id])
      return unless pipeline

      ::OC::Environments::BlueprintDeployment.record_from(pipeline, ::Gitlab.config.gitlab.url)
    end
  end
end
