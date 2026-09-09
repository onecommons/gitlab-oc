# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Dashboard projects API', feature_category: :groups_and_projects do
  include ApiHelpers

  let(:user) { create(:user) }
  let(:dashboard) { create(:project) }
  let(:regular_project) { create(:project) }

  before do
    dashboard.custom_attributes.create!(key: 'unfurl_type', value: OC::UNFURL_DASHBOARD)
    dashboard.add_maintainer(user)
    regular_project.custom_attributes.create!(key: 'unfurl_type', value: OC::REGULAR_PROJECT)
    regular_project.add_maintainer(user)
  end

  it 'lists dashboard projects visible to the authenticated user' do
    get api('/dashboards', user)

    expect(response).to have_gitlab_http_status(:ok)
    expect(json_response.pluck('id')).to contain_exactly(dashboard.id)
  end

  it 'honours a lower minimum access level' do
    other_dashboard = create(:project)
    other_dashboard.custom_attributes.create!(key: 'unfurl_type', value: OC::UNFURL_DASHBOARD)
    other_dashboard.add_guest(user)

    get api('/dashboards', user), params: { min_access_level: ::Gitlab::Access::GUEST }

    expect(response).to have_gitlab_http_status(:ok)
    expect(json_response.pluck('id')).to contain_exactly(dashboard.id, other_dashboard.id)
  end

  it 'requires authentication' do
    get api('/dashboards')

    expect(response).to have_gitlab_http_status(:unauthorized)
  end
end
