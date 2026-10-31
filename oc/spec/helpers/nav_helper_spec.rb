# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NavHelper, feature_category: :navigation do
  describe '#page_with_sidebar_class' do
    it 'starts an overlaid sidebar collapsed' do
      helper.overlay_super_sidebar

      expect(helper.page_with_sidebar_class)
        .to include('page-with-super-sidebar', 'page-with-super-sidebar-collapsed', 'page-with-super-sidebar-overlay')
    end

    it 'leaves other pages to upstream' do
      expect(helper.page_with_sidebar_class).not_to include('page-with-super-sidebar-overlay')
    end
  end

  describe '#super_sidebar_loading_state_class' do
    before do
      helper.request.cookies['super_sidebar_collapsed'] = 'true'
    end

    it 'never reserves the icon-only rail for an overlaid sidebar' do
      helper.overlay_super_sidebar

      expect(helper.super_sidebar_loading_state_class).to eq('')
    end

    it 'leaves other pages to upstream' do
      expect(helper.super_sidebar_loading_state_class).to eq('super-sidebar-is-icon-only')
    end
  end
end
