# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Sidebars::Projects::SuperSidebarPanel, feature_category: :navigation do
  # rubocop: disable RSpec/FactoryBot/AvoidCreate -- the classification attribute needs a real project row
  let(:user) { create(:user, :with_namespace) }
  let(:project) { create(:project, :repository, namespace: user.namespace) }
  # rubocop: enable RSpec/FactoryBot/AvoidCreate
  let(:blueprint_menu) { Sidebars::Projects::Menus::ApplicationBlueprintMenu }

  def panel(current_user = user)
    context = Sidebars::Projects::Context.new(
      current_user: current_user,
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

    described_class.new(context)
  end

  def menus
    panel.instance_variable_get(:@menus).map(&:class)
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

    it 'shows only the flat dashboard menu' do
      expect(menus).to eq([dashboard_menu])
    end

    it 'has no context header' do
      expect(panel.super_sidebar_context_header).to be_nil
    end

    it "lists 15.11's views under the owner's name" do
      items = panel.super_sidebar_menu_items

      expect(items.pluck(:title)).to eq([user.name, *%w[Dashboard Environments Deployments Repository Settings]])
      expect(items.find { |item| item[:id] == :oc_repository }[:link])
        .to eq("/#{project.full_path}/-/tree/#{project.repository.root_ref}")
    end

    context 'when the repository is empty' do
      # rubocop: disable RSpec/FactoryBot/AvoidCreate -- the classification attribute needs a real project row
      let(:project) { create(:project, :empty_repo, namespace: user.namespace) }
      # rubocop: enable RSpec/FactoryBot/AvoidCreate

      it 'leaves out Repository, which has no ref to show' do
        expect(panel.super_sidebar_menu_items.pluck(:title)).not_to include('Repository')
      end
    end

    it 'leaves out Settings for those who cannot change them' do
      project.add_developer(other_user = create(:user)) # rubocop:disable RSpec/FactoryBot/AvoidCreate -- needs a member

      titles = panel(other_user).super_sidebar_menu_items.pluck(:title)

      expect(titles).not_to include('Settings')
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
