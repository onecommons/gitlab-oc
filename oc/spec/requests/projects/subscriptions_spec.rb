# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Dashboard project subscriptions', feature_category: :continuous_integration do
  let_it_be(:maintainer) { create(:user, :with_namespace) }

  let(:upstream) { create(:project, :public) }
  let(:dashboard) do
    create(:project).tap do |project|
      project.record_unfurl_type!(OC::UNFURL_DASHBOARD)
      project.add_maintainer(maintainer)
    end
  end

  def subscribe(project = dashboard, upstream_project = upstream)
    post project_subscriptions_path(project, upstream: upstream_project.full_path, format: :json)
  end

  def unsubscribe(project = dashboard, upstream_project = upstream)
    delete project_subscriptions_path(project, upstream: upstream_project.full_path, format: :json)
  end

  before do
    sign_in(maintainer)
  end

  it 'creates, lists and deletes an upstream subscription' do
    subscribe

    expect(response).to have_gitlab_http_status(:created)
    expect(dashboard.upstream_projects).to contain_exactly(upstream)

    get project_subscriptions_path(dashboard, format: :json)

    expect(response).to have_gitlab_http_status(:ok)
    expect(json_response.map { |p| p['id'] }).to contain_exactly(upstream.id)

    unsubscribe

    expect(response).to have_gitlab_http_status(:ok)
    expect(dashboard.reload.upstream_projects).to be_empty
  end

  it 'takes a second subscribe to the same project as a no-op' do
    subscribe

    expect { subscribe }.not_to change { dashboard.reload.upstream_projects.count }
    expect(response).to have_gitlab_http_status(:ok)
  end

  it 'is closed to a developer of the dashboard' do
    developer = create(:user, :with_namespace)
    dashboard.add_developer(developer)
    sign_in(developer)

    subscribe

    expect(response).to have_gitlab_http_status(:forbidden)
    expect(dashboard.upstream_projects).to be_empty
  end

  it 'refuses an upstream project the user cannot read' do
    subscribe(dashboard, create(:project, :private))

    expect(response).to have_gitlab_http_status(:forbidden)
    expect(dashboard.upstream_projects).to be_empty
  end

  it 'refuses an upstream project that does not exist' do
    delete project_subscriptions_path(dashboard, upstream: 'no/such-project', format: :json)

    expect(response).to have_gitlab_http_status(:forbidden)
  end

  it 'is not offered on a project that is not a dashboard' do
    regular = create(:project).tap do |project|
      project.record_unfurl_type!(OC::REGULAR_PROJECT)
      project.add_maintainer(maintainer)
    end

    subscribe(regular)

    expect(response).to have_gitlab_http_status(:not_found)
    expect(regular.upstream_projects).to be_empty
  end
end
