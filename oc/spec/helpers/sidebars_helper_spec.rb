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
end
