# frozen_string_literal: true

require 'spec_helper'

RSpec.describe User, feature_category: :groups_and_projects do
  def dashboard_of(user)
    user.projects.find_by(path: OC::UNFURL_DASHBOARD_NAME)
  end

  it 'gives a new user a dashboard project, classified before its files arrive' do
    user = create(:user, :with_namespace)
    user.create_dashboard_project!
    dashboard = dashboard_of(user)

    expect(dashboard).to be_present
    expect(dashboard.recorded_unfurl_type).to eq(OC::UNFURL_DASHBOARD)
    expect(user.own_dashboard).to eq(dashboard)
  end

  it 'gives an external user one too, and leaves them external' do
    user = create(:user, :external, :with_namespace)
    user.create_dashboard_project!

    expect(dashboard_of(user)).to be_present
    expect(user.reload).to be_external
    expect(user.projects_limit).to eq(0)
  end

  it 'leaves bots alone' do
    bot = create(:user, :project_bot, :with_namespace)
    bot.create_dashboard_project!

    expect(dashboard_of(bot)).to be_nil
  end
end
