# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Query.project.jobs with a deploy path', feature_category: :continuous_integration do
  include GraphqlHelpers

  let_it_be(:user) { create(:user, :with_namespace) }
  let_it_be(:project) { create(:project, :repository) }
  let_it_be(:pipeline) { create(:ci_pipeline, project: project) }

  let_it_be(:production_job) do
    create(:ci_build, :success, name: 'deploy-production', pipeline: pipeline,
      yaml_variables: [{ key: 'DEPLOY_PATH', value: 'production', public: true }])
  end

  let_it_be(:staging_job) do
    create(:ci_build, :success, name: 'deploy-staging', pipeline: pipeline,
      yaml_variables: [{ key: 'DEPLOY_PATH', value: 'staging', public: true }])
  end

  let(:var_deploy_path) { nil }

  let(:query) do
    graphql_query_for(
      :project, { fullPath: project.full_path },
      query_nodes(:jobs, :name, args: { varDeployPath: var_deploy_path })
    )
  end

  before_all do
    project.add_maintainer(user)
  end

  before do
    post_graphql(query, current_user: user)
  end

  def job_names
    graphql_data_at(:project, :jobs, :nodes).pluck('name')
  end

  context 'when a deploy path is given' do
    let(:var_deploy_path) { 'production' }

    it 'returns only that deployment\'s jobs' do
      expect(job_names).to contain_exactly('deploy-production')
    end
  end

  context 'when no deploy path is given' do
    it 'returns every job' do
      expect(job_names).to contain_exactly('deploy-production', 'deploy-staging')
    end
  end

  context 'when nothing carries the deploy path' do
    let(:var_deploy_path) { 'nowhere' }

    it 'returns nothing rather than everything' do
      expect(job_names).to be_empty
    end
  end
end
