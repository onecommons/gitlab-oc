# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Ci::RecordBlueprintDeploymentWorker, feature_category: :continuous_delivery do
  let_it_be(:blueprint) { create(:project) }
  let_it_be(:deployer) { create(:project) }

  let(:pipeline) { create(:ci_pipeline, project: deployer, status: :success, finished_at: Time.current) }
  let(:event) do
    ::Ci::PipelineFinishedEvent.new(data: {
      pipeline_id: pipeline.id, partition_id: pipeline.partition_id,
      status: 'success', source: 'push', project_id: deployer.id
    })
  end

  before do
    variable = Ci::PipelineVariable.new(pipeline: pipeline, project_id: pipeline.project_id,
      key: 'BLUEPRINT_PROJECT_URL')
    variable.variable_type = 'unencrypted_var'
    variable.value = "#{Gitlab.config.gitlab.url}/#{blueprint.full_path}.git"
    variable.save!
  end

  it_behaves_like 'subscribes to event' do
    let(:event) { ::Ci::PipelineFinishedEvent.new(data: { pipeline_id: pipeline.id, status: 'success' }) }
  end

  it 'records the deployment against the blueprint' do
    expect { described_class.new.handle_event(event) }
      .to change { blueprint.blueprint_deployment_count }.from(0).to(1)
  end

  it 'does nothing when the pipeline has gone' do
    pipeline.destroy!

    expect { described_class.new.handle_event(event) }
      .not_to change { OC::Environments::BlueprintDeployment.count }
  end
end
