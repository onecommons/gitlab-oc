# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Ci::Build, feature_category: :continuous_delivery do
  describe '#variables' do
    let_it_be(:project) { create(:project, :repository) }
    let_it_be(:pipeline) { create(:ci_pipeline, project: project) }

    let(:build) do
      create(:ci_build, :with_deployment, environment: 'production', pipeline: pipeline, project: project)
    end

    it 'leaves a job without a provider environment alone' do
      expect(build.variables.to_hash.keys).not_to include('CLOUDSDK_CORE_PROJECT')
    end

    it 'leaves a job without a deployment alone' do
      plain = create(:ci_build, pipeline: pipeline, project: project)

      expect(plain.variables.to_hash.keys).not_to include('CLOUDSDK_CORE_PROJECT')
    end

    context 'when the environment has a cloud provider' do
      before do
        create(:oc_environment_provider, :gcp, environment: build.deployment.environment)
      end

      it 'adds the provider variables to the upstream ones' do
        variables = build.variables.to_hash

        expect(variables).to include(
          'CLOUDSDK_CORE_PROJECT' => 'unfurl-example',
          'CLOUDSDK_COMPUTE_ZONE' => 'us-central1-a',
          'CI_JOB_NAME' => build.name
        )
      end

      it 'does not append twice when called again' do
        first = build.variables.size

        expect(build.variables.size).to eq(first)
      end
    end
  end

  describe '#options_scheduled_at' do
    let(:build) { create(:ci_build, :created, pipeline: create(:ci_pipeline)) }

    # 19.3 moved options onto Ci::JobDefinition, leaving Ci::Build a reader.
    def schedule_for(start_in, variables: {})
      allow(build).to receive_messages(
        options: { start_in: start_in },
        simple_variables: Gitlab::Ci::Variables::Collection.new(
          variables.map { |key, value| { key: key.to_s, value: value } }
        )
      )

      build.options_scheduled_at
    end

    it 'expands a delay the deployment passed as a variable' do
      expect(schedule_for('$START_IN', variables: { START_IN: '3 weeks' }))
        .to be_within(1.minute).of(3.weeks.from_now)
    end

    it 'still reads a literal duration' do
      expect(schedule_for('5 minutes')).to be_within(1.minute).of(5.minutes.from_now)
    end

    it 'is nil when the variable resolves to nothing usable' do
      expect(schedule_for('$START_IN', variables: { START_IN: '' })).to be_nil
    end
  end
end
