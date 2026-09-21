# frozen_string_literal: true

require 'spec_helper'

RSpec.describe EmailsHelper, feature_category: :notifications do
  describe '#header_logo' do
    context 'with no custom appearance' do
      before do
        allow(helper).to receive(:current_appearance).and_return(nil)
      end

      it 'serves the fork logo, named by the brand' do
        expect(helper.header_logo).to include('unfurl_logo', 'alt="Unfurl Cloud"')
      end
    end

    context 'when an admin has uploaded a non-SVG header logo' do
      let(:appearance) { build_stubbed(:appearance, :with_header_logo) }

      before do
        allow(helper).to receive(:current_appearance).and_return(appearance)
      end

      it 'leaves their choice alone' do
        expect(helper.header_logo).to include(appearance.header_logo_path)
      end
    end
  end

  describe 'account notices' do
    it 'names the fork rather than the edition it was cut from' do
      expect(helper.two_factor_authentication_disabled_text).to eq(
        'Two-factor authentication has been disabled for your Unfurl Cloud account.'
      )
      expect(helper.new_email_address_added_text('a@example.com')).to eq(
        'A new email address has been added to your Unfurl Cloud account: a@example.com'
      )
      expect(helper.admin_changed_password_text).to start_with(
        'An administrator changed the password for your Unfurl Cloud account on'
      )
      expect(helper.instance_access_request_text(build_stubbed(:user, name: 'Bob'))).to start_with(
        'Bob has asked for a Unfurl Cloud account on your instance'
      )
    end

    # The template is marked safe so that `%` escapes what it interpolates;
    # marking the finished string safe instead would inject the name raw.
    it 'still escapes a name that contains markup' do
      user = build_stubbed(:user, name: 'Bob <script>')

      expect(helper.instance_access_request_text(user, format: :html)).to include('Bob &lt;script&gt;')
    end
  end
end
