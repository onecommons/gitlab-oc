# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Sidebars::Help::Panel, feature_category: :navigation do
  # A help centre is read signed out more often than signed in.
  let(:context) { Sidebars::Context.new(current_user: nil, container: nil) }

  subject(:panel) { described_class.new(context) }

  it_behaves_like 'a panel with uniquely identifiable menu items'

  it 'implements #super_sidebar_context_header' do
    expect(panel.super_sidebar_context_header).to eq(_('Help'))
  end

  it 'carries the table of contents of the fork help centre' do
    expect(panel.renderable_menus.map(&:title))
      .to eq(['Introduction', 'User Guides', 'Developer Guide'])
  end

  it 'links every entry into /help' do
    links = panel.renderable_menus.flat_map do |menu|
      menu.has_items? ? menu.renderable_items.map(&:link) : [menu.link]
    end

    expect(links).to eq([
      '/help#what-is-unfurl-cloud',
      '/help#why-unfurl-cloud',
      '/help/guides/getting_started_aws.md',
      '/help/guides/getting_started_gcp.md',
      '/help#developer-guide'
    ])
  end
end
