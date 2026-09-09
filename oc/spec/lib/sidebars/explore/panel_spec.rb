# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Sidebars::Explore::Panel, feature_category: :navigation do
  let(:panel) { described_class.new(Sidebars::Context.new(current_user: nil, container: nil)) }

  def titles
    panel.instance_variable_get(:@menus).map(&:title)
  end

  it 'leads with blueprints, offers the cloud and drops snippets' do
    expect(titles.first).to eq('Blueprints')
    expect(titles).to include('Cloud')
    expect(titles).not_to include('Snippets')
  end
end
