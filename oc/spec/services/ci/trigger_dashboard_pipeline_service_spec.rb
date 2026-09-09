# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Ci::TriggerDashboardPipelineService, feature_category: :pipeline_composition do
  let_it_be(:upstream_project, refind: true) { create(:project, :repository) }
  let_it_be(:dashboard) { create(:project, :repository) }
  let_it_be(:bot) { create(:user, :project_bot) }

  let(:current_user) { upstream_project.first_owner }
  let(:created_pipeline) { instance_double(Ci::Pipeline, created_successfully?: true) }
  let(:pipeline_creator) { instance_double(Ci::CreatePipelineService) }

  subject(:service) { described_class.new(project: upstream_project, current_user: current_user) }

  before_all do
    dashboard.add_maintainer(bot)
  end

  before do
    allow(Ci::CreatePipelineService).to receive(:new).and_return(pipeline_creator)
    allow(pipeline_creator).to receive(:execute)
      .with(:pipeline, ignore_skip_ci: true).and_return(ServiceResponse.success(payload: created_pipeline))
  end

  context 'when a dashboard is subscribed' do
    before do
      OC::Ci::Subscriptions::Project.create!(upstream_project: upstream_project, downstream_project: dashboard)
    end

    it 'runs the downstream pipeline as the dashboard bot, with the subscription named' do
      link = upstream_project.downstream_project_subscriptions.first

      service.execute(nil, UPSTREAM_PROJECT: 123, UPSTREAM_BRANCH: 'main', DEPLOYMENT_ENABLED: true)

      expect(Ci::CreatePipelineService).to have_received(:new).with(
        dashboard,
        bot,
        ref: dashboard.default_branch,
        variables_attributes: match_array([
          { key: 'UPSTREAM_PROJECT', value: '123' },
          { key: 'UPSTREAM_BRANCH', value: 'main' },
          { key: 'DEPLOYMENT_ENABLED', value: 'true' },
          { key: 'UPSTREAM_SUBSCRIPTION_ID', value: link.id.to_s }
        ])
      )
    end

    it 'reports success' do
      expect(service.execute(nil)[:status]).to eq(:success)
    end
  end

  it 'leaves an unsubscribed project alone' do
    create(:project)

    service.execute(nil, UPSTREAM_PROJECT: upstream_project.id)

    expect(Ci::CreatePipelineService).not_to have_received(:new)
  end

  # The pipeline chain authorizes the user it is given, so this grants nothing
  # an outsider does not already have -- it just keeps a bot-less dashboard
  # redeploying, as it did in 15.11.
  it 'falls back to the triggering user when the dashboard has no bot' do
    botless = create(:project, :repository)
    OC::Ci::Subscriptions::Project.create!(upstream_project: upstream_project, downstream_project: botless)

    service.execute(nil, UPSTREAM_PROJECT: upstream_project.id)

    expect(Ci::CreatePipelineService).to have_received(:new).with(botless, current_user, anything)
  end

  it 'skips only when there is nobody at all to run it as' do
    botless = create(:project, :repository)
    OC::Ci::Subscriptions::Project.create!(upstream_project: upstream_project, downstream_project: botless)

    expect(Gitlab::AppLogger).to receive(:info).with(hash_including(project_id: botless.id))

    described_class.new(project: upstream_project, current_user: nil)
      .execute(nil, UPSTREAM_PROJECT: upstream_project.id)

    expect(Ci::CreatePipelineService).not_to have_received(:new)
  end
end
