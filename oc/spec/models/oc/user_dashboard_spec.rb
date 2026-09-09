# frozen_string_literal: true

require 'spec_helper'

RSpec.describe User, feature_category: :groups_and_projects do
  let(:user) { create(:user, :with_namespace) }
  let(:owned_dashboard) { create(:project, namespace: user.namespace) }
  let(:member_dashboard) { create(:project) }
  let(:regular_project) { create(:project) }

  before do
    [owned_dashboard, member_dashboard].each do |project|
      project.custom_attributes.create!(key: 'unfurl_type', value: OC::UNFURL_DASHBOARD)
      project.add_maintainer(user)
    end
    regular_project.custom_attributes.create!(key: 'unfurl_type', value: OC::REGULAR_PROJECT)
    regular_project.add_maintainer(user)
  end

  it 'returns only dashboard projects the user can maintain and selects the owned dashboard' do
    expect(user.dashboards).to contain_exactly(owned_dashboard, member_dashboard)
    expect(user.own_dashboard).to eq(owned_dashboard)
    expect(user.active_dashboard).to eq(owned_dashboard)
  end

  it 'uses an explicitly selected dashboard for the lifetime of the user object' do
    user.active_dashboard = member_dashboard

    expect(user.active_dashboard).to eq(member_dashboard)
  end
end
