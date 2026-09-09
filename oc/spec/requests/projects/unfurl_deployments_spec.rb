# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Unfurl deployment trigger', feature_category: :continuous_delivery do
  let_it_be(:user) { create(:user, :with_namespace) }
  let_it_be(:bot) { create(:user) }

  let(:dashboard) do
    create(:project, :repository).tap do |project|
      project.record_unfurl_type!(OC::UNFURL_DASHBOARD)
      project.add_maintainer(user)
    end
  end

  let(:pipeline) { build_stubbed(:ci_pipeline, project: dashboard) }
  let(:captured) { {} }

  def trigger(project: dashboard, dependencies: {}, schedule: 'now', variables: [])
    post project_trigger_unfurl_deployment_path(project),
      params: {
        deployment: { bot_id: bot.id, schedule: schedule, project_dependencies: dependencies },
        pipeline: { ref: 'master', variables_attributes: variables }
      }
  end

  def stub_pipeline_creation(success: true)
    service = instance_double(Ci::CreatePipelineService)
    response = if success
                 ServiceResponse.success(payload: pipeline)
               else
                 ServiceResponse.error(message: 'nope', payload: pipeline)
               end

    allow(Ci::CreatePipelineService).to receive(:new) do |_project, pipeline_user, pipeline_params|
      captured[:user] = pipeline_user
      captured[:params] = pipeline_params
      service
    end
    allow(service).to receive(:execute)
      .with(:web, ignore_skip_ci: true, save_on_errors: false).and_return(response)
    allow(PipelineSerializer).to receive(:new)
      .and_return(instance_double(PipelineSerializer, represent: {}))
  end

  before do
    sign_in(user)
  end

  context 'with no dependencies' do
    before do
      stub_pipeline_creation
    end

    it 'runs the pipeline as the bot and passes the delay as START_IN' do
      trigger(schedule: '3 weeks', variables: [{ key: 'DEPLOY_TARGET', variable_type: 'env_var',
                                                 secret_value: 'production' }])

      expect(response).to have_gitlab_http_status(:created)
      expect(captured[:user]).to eq(bot)
      expect(captured[:params][:variables_attributes]).to include(
        hash_including(key: 'START_IN', value: '3 weeks'),
        hash_including(key: 'DEPLOY_TARGET', value: 'production')
      )
    end

    it "reads 'now' as no delay at all" do
      trigger(schedule: 'now')

      expect(captured[:params][:variables_attributes]).to include(
        hash_including(key: 'START_IN', value: '0 seconds')
      )
    end

    it 'reports the pipeline errors when creation fails' do
      stub_pipeline_creation(success: false)
      allow(pipeline).to receive_messages(error_messages: [], warning_messages: [])

      trigger

      expect(response).to have_gitlab_http_status(:bad_request)
    end
  end

  describe 'deploy tokens for dependencies' do
    let(:upstream) { create(:project, :private) }

    before do
      stub_pipeline_creation
    end

    it 'creates a token, stores it masked, and does not re-create it next time' do
      upstream.add_maintainer(user)

      expect { trigger(dependencies: { upstream.full_path => 'UPSTREAM_TOKEN' }) }
        .to change { upstream.deploy_tokens.count }.by(1)

      variable = dashboard.variables.find_by(key: 'UPSTREAM_TOKEN')
      expect(response).to have_gitlab_http_status(:created)
      expect(variable.value).to eq(upstream.deploy_tokens.last.token)
      expect(variable).to be_masked

      expect { trigger(dependencies: { upstream.full_path => 'UPSTREAM_TOKEN' }) }
        .not_to change { upstream.deploy_tokens.count }
    end

    it 'updates the stored variable when it has drifted from the token' do
      upstream.add_maintainer(user)
      trigger(dependencies: { upstream.full_path => 'UPSTREAM_TOKEN' })

      variable = dashboard.variables.find_by(key: 'UPSTREAM_TOKEN')
      # A masked variable has to look like a token, so drift it to another one.
      variable.update!(value: 'obsoletedeploytoken1234')

      trigger(dependencies: { upstream.full_path => 'UPSTREAM_TOKEN' })

      expect(response).to have_gitlab_http_status(:created)
      expect(variable.reload.value).to eq(upstream.deploy_tokens.last.token)
    end

    it 'needs no token for a public dependency' do
      public_upstream = create(:project, :public)

      expect { trigger(dependencies: { public_upstream.full_path => 'UPSTREAM_TOKEN' }) }
        .not_to change { DeployToken.count }

      expect(response).to have_gitlab_http_status(:created)
    end

    it 'refuses when the user cannot read the dependency' do
      expect(Ci::CreatePipelineService).not_to receive(:new)

      trigger(dependencies: { upstream.full_path => 'UPSTREAM_TOKEN' })

      expect(response).to have_gitlab_http_status(:bad_request)
      expect(json_response['message']).to eq('failed to create tokens')
    end

    it 'refuses when the dependency does not exist' do
      trigger(dependencies: { 'no/such-project' => 'UPSTREAM_TOKEN' })

      expect(response).to have_gitlab_http_status(:bad_request)
      expect(json_response['errors'].first['message']).to eq('404 upstream project not found')
    end
  end

  describe 'who may trigger one' do
    it 'is not offered for a project that is not a dashboard' do
      regular = create(:project, :repository).tap { |p| p.add_maintainer(user) }
      regular.record_unfurl_type!(OC::REGULAR_PROJECT)

      expect(Ci::CreatePipelineService).not_to receive(:new)

      trigger(project: regular)

      expect(response).to have_gitlab_http_status(:not_found)
    end

    it 'is not open to a guest' do
      guest = create(:user, :with_namespace)
      dashboard.add_guest(guest)
      sign_in(guest)

      expect(Ci::CreatePipelineService).not_to receive(:new)

      trigger

      expect(response).to have_gitlab_http_status(:not_found)
    end

    it 'is not open to an anonymous request' do
      sign_out(user)

      trigger

      expect(response).to redirect_to(new_user_session_path)
    end
  end
end
