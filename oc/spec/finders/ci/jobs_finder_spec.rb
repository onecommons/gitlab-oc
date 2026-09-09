# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Ci::JobsFinder, '#execute', feature_category: :continuous_integration do
  let_it_be(:project) { create(:project) }
  let_it_be(:user) { create(:user, :with_namespace) }
  let_it_be(:pipeline) { create(:ci_pipeline, project: project) }

  let_it_be(:production_job) do
    create(:ci_build, :success, pipeline: pipeline, yaml_variables: [
      { key: 'DEPLOY_PATH', value: 'production', public: true },
      { key: 'REGION', value: 'us-east-1', public: true }
    ])
  end

  let_it_be(:staging_job) do
    create(:ci_build, :success, pipeline: pipeline, yaml_variables: [
      { key: 'DEPLOY_PATH', value: 'staging', public: true },
      { key: 'REGION', value: 'us-east-1', public: true }
    ])
  end

  let_it_be(:wrong_region_job) do
    create(:ci_build, :success, pipeline: pipeline, yaml_variables: [
      { key: 'DEPLOY_PATH', value: 'production', public: true },
      { key: 'REGION', value: 'eu-west-1', public: true }
    ])
  end

  let(:params) { {} }

  subject(:jobs) { described_class.new(current_user: user, project: project, params: params).execute }

  before_all do
    project.add_maintainer(user)
  end

  context 'with a deployment-path filter' do
    let(:params) { { var_deploy_path: 'production' } }

    it { is_expected.to contain_exactly(production_job, wrong_region_job) }
  end

  context 'with two filters' do
    let(:params) { { var_deploy_path: 'production', var_region: 'us-east-1' } }

    it 'requires every one to match' do
      is_expected.to contain_exactly(production_job)
    end
  end

  context 'when nothing matches' do
    let(:params) { { var_deploy_path: 'nowhere' } }

    it { is_expected.to be_empty }
  end

  it 'leaves the jobs alone when no variable filter is supplied' do
    is_expected.to contain_exactly(production_job, staging_job, wrong_region_job)
  end

  it 'returns a relation, so the caller can go on scoping it' do
    finder = described_class.new(current_user: user, project: project, params: { var_deploy_path: 'production' })

    expect(finder.execute).to be_a(ActiveRecord::Relation)
    expect(finder.execute.where(id: production_job.id)).to contain_exactly(production_job)
  end
end
