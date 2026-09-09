# frozen_string_literal: true

require 'spec_helper'

RSpec.describe AppearancesHelper, feature_category: :navigation do
  describe '#default_brand_title' do
    it 'names the fork, not the edition it was cut from' do
      expect(helper.default_brand_title).to eq('Unfurl')
    end
  end

  describe '#brand_image_path' do
    context 'with no custom appearance' do
      before do
        allow(helper).to receive(:current_appearance).and_return(nil)
      end

      it 'serves the fork wordmark' do
        expect(helper.brand_image_path).to match(%r{/uf-logo.*\.svg\z})
      end
    end

    context 'when an admin has uploaded a logo' do
      let(:appearance) { build_stubbed(:appearance, :with_logo) }

      before do
        allow(helper).to receive(:current_appearance).and_return(appearance)
      end

      it 'leaves their choice alone' do
        expect(helper.brand_image_path).to eq(appearance.logo_path)
      end
    end
  end
end
