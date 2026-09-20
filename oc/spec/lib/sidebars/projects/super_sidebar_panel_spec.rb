# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Sidebars::Projects::SuperSidebarPanel, feature_category: :navigation do
  # rubocop: disable RSpec/FactoryBot/AvoidCreate -- the classification attribute needs a real project row
  let(:user) { create(:user) }
  let(:project) { create(:project, :repository) }
  # rubocop: enable RSpec/FactoryBot/AvoidCreate
  let(:blueprint_menu) { Sidebars::Projects::Menus::ApplicationBlueprintMenu }

  def menus
    context = Sidebars::Projects::Context.new(
      current_user: user,
      container: project,
      current_ref: project.repository.root_ref,
      is_super_sidebar: true,
      can_view_pipeline_editor: true,
      learn_gitlab_enabled: false,
      show_get_started_menu: false,
      show_discover_project_security: false,
      show_cluster_hint: false,
      show_promotions: false
    )

    described_class.new(context).instance_variable_get(:@menus).map(&:class)
  end

  before do
    project.add_maintainer(user)
  end

  it 'leads a blueprint project with its overview' do
    project.custom_attributes.create!(key: 'unfurl_type', value: OC::UNFURL_BLUEPRINT)

    expect(menus).to include(blueprint_menu)
    expect(menus.index(blueprint_menu))
      .to be < menus.index(Sidebars::Projects::SuperSidebarMenus::ManageMenu)
  end

  it 'leaves an ordinary project alone' do
    project.custom_attributes.create!(key: 'unfurl_type', value: OC::REGULAR_PROJECT)

    expect(menus).not_to include(blueprint_menu)
  end

  context 'when the project is a dashboard' do
    let(:dashboard_menu) { Sidebars::Projects::Menus::UnfurlDashboardMenu }

    before do
      project.custom_attributes.create!(key: 'unfurl_type', value: OC::UNFURL_DASHBOARD)
    end

    it 'leads with the dashboard views and drops the repository machinery' do
      expect(menus.first(2)).to include(dashboard_menu)
      expect(menus).to include(
        Sidebars::Projects::SuperSidebarMenus::CodeMenu,
        Sidebars::Projects::Menus::SettingsMenu
      )
      expect(menus).not_to include(
        Sidebars::Projects::SuperSidebarMenus::ManageMenu,
        Sidebars::Projects::SuperSidebarMenus::PlanMenu,
        Sidebars::Projects::SuperSidebarMenus::DeployMenu,
        Sidebars::Projects::SuperSidebarMenus::MonitorMenu
      )
    end

    it 'offers the dashboard views that have a page behind them' do
      context = Sidebars::Projects::Context.new(
        current_user: user, container: project, current_ref: project.repository.root_ref
      )
      items = dashboard_menu.new(context).renderable_items.map(&:title)

      expect(items).to eq(%w[Overview Environments Deployments])
    end
  end

  it 'hides the deployment machinery from a simple-interface user' do
    user.update!(external: true)

    expect(menus).not_to include(
      Sidebars::Projects::SuperSidebarMenus::DeployMenu,
      Sidebars::Projects::SuperSidebarMenus::OperationsMenu,
      Sidebars::Projects::SuperSidebarMenus::MonitorMenu,
      Sidebars::Projects::SuperSidebarMenus::SecureMenu
    )
    expect(menus).to include(Sidebars::Projects::SuperSidebarMenus::CodeMenu)
  end

  it 'leaves them for everyone else' do
    expect(menus).to include(Sidebars::Projects::SuperSidebarMenus::DeployMenu)
  end

  it 'does not classify while rendering' do
    expect { menus }.not_to change { project.custom_attributes.count }
  end
end
