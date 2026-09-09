# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Ci::TriggerDashboardPipelineWorker, feature_category: :pipeline_composition do
  let_it_be(:project) { create(:project) }
  let(:pipeline) { create(:ci_pipeline, project: project, sha: 'abc123', ref: 'main') }

  let(:event) do
    ::Ci::PipelineFinishedEvent.new(data: {
      pipeline_id: pipeline.id, status: status, partition_id: pipeline.partition_id
    })
  end

  let(:status) { 'success' }

  it_behaves_like 'subscribes to event'

  # The only cover for the `if:` on the subscription, which filters on status
  # at publish rather than waking a job for every finished pipeline.
  describe 'the subscription condition' do
    it 'wakes for a pipeline that passed' do
      expect(described_class).to receive(:perform_async)

      ::Gitlab::EventStore.publish(event)
    end

    context 'when the pipeline did not pass' do
      let(:status) { 'failed' }

      it 'stays asleep' do
        expect(described_class).not_to receive(:perform_async)

        ::Gitlab::EventStore.publish(event)
      end
    end
  end

  describe '#handle_event' do
    let(:service) { instance_double(Ci::TriggerDashboardPipelineService, execute: nil) }

    it 'dispatches with the upstream details the deployment filters on' do
      allow(Ci::TriggerDashboardPipelineService).to receive(:new).and_return(service)

      described_class.new.handle_event(event)

      expect(service).to have_received(:execute).with(
        pipeline,
        hash_including(
          UPSTREAM_PROJECT: project.id.to_s,
          UPSTREAM_REPO: project.path_with_namespace,
          UPSTREAM_COMMIT: 'abc123',
          UPSTREAM_PIPELINE: pipeline.id.to_s
        )
      )
    end

    it 'leaves a dashboard alone, so a redeploy cannot trigger itself' do
      project.record_unfurl_type!(OC::UNFURL_DASHBOARD)

      expect(Ci::TriggerDashboardPipelineService).not_to receive(:new)

      described_class.new.handle_event(event)
    end

    it 'does nothing when the pipeline has gone' do
      pipeline.destroy!

      expect(Ci::TriggerDashboardPipelineService).not_to receive(:new)

      described_class.new.handle_event(event)
    end
  end
end
