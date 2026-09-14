# frozen_string_literal: true

require 'spec_helper'

RSpec.describe AppearancesHelper, feature_category: :user_profile do
  describe '#brand_image' do
    it 'leaves the logo to the brand column, which carries it in the sentence' do
      expect(helper.brand_image).to be_blank
    end

    it 'puts it above the form when the instance supplies its own description' do
      appearance = build_stubbed(:appearance, description: 'Our own words')
      allow(helper).to receive(:current_appearance).and_return(appearance)

      tag = helper.brand_image

      expect(tag).to include('uf-logo')
      expect(tag).not_to include('lazy')
      expect(tag).not_to include('gl-invisible')
    end
  end

  describe '#custom_sign_in_description' do
    before do
      # markdown_field reaches for the signed-in user; the sign-in page has none.
      allow(helper).to receive(:current_user).and_return(nil)
    end

    it 'gives the sign-in page a brand column when the instance has set none' do
      expect(helper.custom_sign_in_description).to include('Welcome to')
        .and include('The maker space for a better Internet.')
        .and include('oc-brand-holder')
      # The wordmark sits between the two, completing the sentence, and ships
      # with its dark counterpart for CSS to choose between.
      expect(helper.custom_sign_in_description).to include('uf-logo')
        .and include('uf-logo-white')
    end

    it 'defers to an appearance the instance has configured' do
      appearance = build_stubbed(:appearance, description: 'Our own words')
      allow(helper).to receive(:current_appearance).and_return(appearance)
      # markdown_field caches its render back to the row, which a stubbed
      # model cannot do; the branch is what this example is about.
      allow(helper).to receive(:markdown_field).with(appearance, :description).and_return('Our own words')

      expect(helper.custom_sign_in_description).to include('Our own words')
      expect(helper.custom_sign_in_description).not_to include('oc-brand-holder')
    end
  end
end
