# frozen_string_literal: true

require 'spec_helper'

RSpec.describe PageLayoutHelper, feature_category: :navigation do
  describe '#favicon' do
    # Everything but development already resolves favicon.png to the fork's
    # copy, which sits earlier on the asset path than upstream's.
    it 'shows the fork mark in development, where upstream shows a blue one' do
      stub_rails_env('development')

      expect(helper.favicon).to match_asset_path 'assets/favicon.png'
    end

    it 'steps aside for an instance that uploaded its own' do
      stub_rails_env('development')
      appearance = build_stubbed(:appearance)
      allow(::Appearance).to receive(:current).and_return(appearance)
      allow(appearance.favicon).to receive(:exists?).and_return(true)
      allow(::Gitlab::Favicon).to receive(:main).and_return('/uploads/favicon.png')

      expect(helper.favicon).to eq('/uploads/favicon.png')
    end
  end

  describe '#overlay_super_sidebar' do
    it 'is off until a view asks for it' do
      helper.nav('project')

      expect(helper.overlay_super_sidebar?).to be(false)
      expect(helper.nav).to eq('project')
    end

    it "takes the nav over from the layout's, which is set after the view" do
      helper.overlay_super_sidebar(nav: 'explore')
      helper.nav('project')

      expect(helper.overlay_super_sidebar?).to be(true)
      expect(helper.nav).to eq('explore')
    end

    it "leaves the nav alone when it isn't given one" do
      helper.overlay_super_sidebar
      helper.nav('explore')

      expect(helper.nav).to eq('explore')
    end
  end

  describe '#page_image' do
    it 'defaults to the fork mark' do
      expect(helper.page_image).to match_asset_path 'assets/uf-logo.png'
    end

    it 'still prefers the subject avatar' do
      project = build_stubbed(:project, :with_avatar)
      assign(:project, project)

      expect(helper.page_image).to eq(project.avatar_url(only_path: false))
    end
  end
end
