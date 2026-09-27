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

          # Unfiltered, unlike the two above: the cloudmap records a run's
          # status as a property of the run, so a failure is a change too.
          store.subscribe ::OC::Repositories::MirrorSyncedWorker, to: ::OC::Repositories::MirrorSyncedEvent

          store.subscribe ::OC::Projects::RecordCloudmapEventWorker,
            to: [
              ::Projects::ProjectVisibilityChangedEvent,
              ::Ci::PipelineFinishedEvent,
              ::Packages::PackageCreatedEvent,
              ::OC::ContainerRegistry::ImageChangedEvent,
              ::OC::Repositories::MirrorSyncedEvent
            ]
        end
      end
    end
  end
end
