# frozen_string_literal: true

require 'spec_helper'

RSpec.describe SidebarsHelper, feature_category: :navigation do
  include Devise::Test::ControllerHelpers

  let_it_be(:current_organization) { build_stubbed(:common_organization) }

  # Only asked for menu items and a context header, both of which the shared
  # context passes straight through.
  let(:panel) { double('panel').as_null_object } # rubocop:disable RSpec/VerifiedDoubles -- a Sidebars::Panel stand-in

  subject(:context) { helper.super_sidebar_shared_context(panel: panel, panel_type: 'project') }

  before do
    Current.organization = current_organization
    allow(helper).to receive_messages(display_whats_new?: true, show_version_check?: true)
  end

  describe '#super_sidebar_shared_context' do
    it "hides the version badge and What's new even when upstream would show them" do
      expect(context).to include(display_whats_new: false, show_version_check: false)
    end
  end

  describe '#super_sidebar_nav_panel' do
    it 'serves the help centre its own panel' do
      expect(helper.super_sidebar_nav_panel(nav: 'help', user: nil))
        .to be_a(::Sidebars::Help::Panel)
    end

    it 'leaves every other section to upstream' do
      expect(helper.super_sidebar_nav_panel(nav: 'explore', user: nil))
        .to be_a(::Sidebars::Explore::Panel)
    end
  end

  describe '#super_sidebar_context' do
    let_it_be(:user) { build_stubbed(:user) }
    let(:project) { nil }

    subject(:links) do
      helper.super_sidebar_context(user, group: nil, project: project, panel: panel, panel_type: 'explore')
             .fetch(:edition_topbar_links)
    end

    # Upstream's half of the context needs the whole view scaffolding; the
    # fork's contribution is the merge on top of it.
    before do
      allow(helper).to receive(:super_sidebar_logged_in_context).and_return({})
    end

    it 'carries the fork sections the 15.11 header had' do
      expect(links.map { |link| link[:text] }).to eq(%w[Dashboard Blueprints Cloud])
      # Not literal paths: route helpers prefix the organization when the
      # current one is not the default.
      expect(links.map { |link| link[:href] })
        .to match([%r{/home\z}, %r{/explore/blueprints\z}, %r{/cloud\z}])
    end

    it 'marks none of them outside those sections' do
      expect(links.map { |link| link[:active] }).to all(be(false))
    end

    context 'when a blueprint project is open' do
      let(:project) { build_stubbed(:project) }

      before do
        allow(project).to receive(:recorded_unfurl_type).and_return(::OC::UNFURL_BLUEPRINT)
      end

      it 'marks Blueprints' do
        expect(links.find { |link| link[:text] == 'Blueprints' }).to include(active: true)
      end
    end

    context 'when a dashboard project is open' do
      let(:project) { build_stubbed(:project) }

      before do
        allow(project).to receive(:recorded_unfurl_type).and_return(::OC::UNFURL_DASHBOARD)
      end

      it 'marks Dashboard' do
        expect(links.find { |link| link[:text] == 'Dashboard' }).to include(active: true)
      end
    end
  end
end
