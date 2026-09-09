# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Sidebars::YourWork::Panel, feature_category: :navigation do
  let(:user) { build_stubbed(:user) }
  let(:panel) { described_class.new(Sidebars::Context.new(current_user: user, container: user)) }

  def titles
    panel.instance_variable_get(:@menus).map(&:title)
  end

  it 'adds the fork entries, with Dashboard above Projects' do
    expect(titles).to include('Dashboard', 'Blueprints', 'Cloud')
    expect(titles.index('Dashboard')).to be < titles.index('Projects')
  end
end
