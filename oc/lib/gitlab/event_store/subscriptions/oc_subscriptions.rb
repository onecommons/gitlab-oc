# frozen_string_literal: true

module Gitlab
  module EventStore
    module Subscriptions
      class OCSubscriptions < BaseSubscriptions
        def register
          # The status is in the payload, so it filters here rather than waking
          # a job for every finished pipeline on the instance.
          store.subscribe ::Ci::TriggerDashboardPipelineWorker,
            to: ::Ci::PipelineFinishedEvent,
            if: ->(event) { event.data[:status] == 'success' }

          store.subscribe ::Ci::RecordBlueprintDeploymentWorker,
            to: ::Ci::PipelineFinishedEvent,
            if: ->(event) { event.data[:status] == 'success' }
        end
      end
    end
  end
end
