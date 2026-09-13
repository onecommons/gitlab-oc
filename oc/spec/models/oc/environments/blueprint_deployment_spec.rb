# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OC::Environments::BlueprintDeployment, feature_category: :continuous_delivery do
  let_it_be(:blueprint) { create(:project, path: 'minecraft') }
  let_it_be(:deployer) { create(:project) }

  let(:root_url) { Gitlab.config.gitlab.url }
  let(:blueprint_url) { "#{root_url}/#{blueprint.full_path}.git" }
  let(:pipeline) { create(:ci_pipeline, project: deployer, finished_at: Time.current) }

  def add_blueprint_variable(value)
    variable = Ci::PipelineVariable.new(pipeline: pipeline, project_id: pipeline.project_id,
      key: described_class::BLUEPRINT_URL_VARIABLE)
    variable.variable_type = 'unencrypted_var'
    variable.value = value
    variable.save!
  end

  describe '.blueprint_for' do
    it 'resolves a url on this instance to its project' do
      expect(described_class.blueprint_for(blueprint_url, root_url)).to eq(blueprint)
    end

    it 'ignores a blueprint hosted somewhere else' do
      expect(described_class.blueprint_for("https://elsewhere.test/#{blueprint.full_path}.git", root_url)).to be_nil
    end

    it 'ignores a blank or pathless url' do
      expect(described_class.blueprint_for(nil, root_url)).to be_nil
      expect(described_class.blueprint_for(root_url, root_url)).to be_nil
    end
  end

  describe '.record_from' do
    it 'records the deployment against the blueprint' do
      add_blueprint_variable(blueprint_url)

      expect { described_class.record_from(pipeline, root_url) }
        .to change { described_class.for_blueprint(blueprint).count }.by(1)

      record = described_class.for_blueprint(blueprint).last
      expect(record.deployed_project).to eq(deployer)
      expect(record.finished_at).to be_within(1.second).of(pipeline.finished_at)
    end

    it 'is a no-op for a pipeline that names no blueprint' do
      expect { described_class.record_from(pipeline, root_url) }
        .not_to change { described_class.count }
    end

    it 'counts a redelivered event once' do
      add_blueprint_variable(blueprint_url)
      described_class.record_from(pipeline, root_url)

      expect { described_class.record_from(pipeline, root_url) }
        .not_to change { described_class.count }
    end
  end

  it 'reads back through the project as a deployment count' do
    add_blueprint_variable(blueprint_url)
    described_class.record_from(pipeline, root_url)

    expect(blueprint.blueprint_deployment_count).to eq(1)
    expect(deployer.blueprint_deployment_count).to eq(0)
  end
end
