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

  it 'does not classify while rendering' do
    expect { menus }.not_to change { project.custom_attributes.count }
  end
end
