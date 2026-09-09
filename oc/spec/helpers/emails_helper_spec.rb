# frozen_string_literal: true

require 'spec_helper'

RSpec.describe EmailsHelper, feature_category: :notifications do
  describe '#header_logo' do
    context 'with no custom appearance' do
      before do
        allow(helper).to receive(:current_appearance).and_return(nil)
      end

      it 'serves the fork logo, named by the brand' do
        expect(helper.header_logo).to include('unfurl_logo', 'alt="Unfurl"')
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
        'Two-factor authentication has been disabled for your Unfurl account.'
      )
      expect(helper.new_email_address_added_text('a@example.com')).to eq(
        'A new email address has been added to your Unfurl account: a@example.com'
      )
    end
  end
end
