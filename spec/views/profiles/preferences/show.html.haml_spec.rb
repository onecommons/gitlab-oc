# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'profiles/preferences/show', feature_category: :user_profile do
  using RSpec::Parameterized::TableSyntax

  let_it_be(:user) { create_default(:user) }

  before do
    assign(:user, user)
    allow(controller).to receive(:current_user).and_return(user)
  end

  describe 'appearance' do
    before do
      render
    end

    it 'has an id for anchoring' do
      expect(rendered).to have_css('#appearance')
    end
  end

  # OC Change -- no accent theme picker, and the hidden field is what keeps
  # profile_preferences.vue's save path from dereferencing a missing theme.
  describe 'application theme' do
    before do
      render
    end

    it 'offers no theme picker' do
      expect(rendered).not_to have_css('#application-theme')
    end

    it 'still submits the theme the user already has' do
      expect(rendered).to have_field(
        'user[theme_id]', type: :hidden, with: Gitlab::Themes.for_user(user).id.to_s
      )
    end
  end

  describe 'syntax highlighting theme' do
    before do
      render
    end

    it 'has an id for anchoring' do
      expect(rendered).to have_css('#syntax-highlighting-theme')
    end
  end

  describe 'behavior' do
    before do
      render
    end

    it 'has option for Render whitespace characters in the Web IDE' do
      expect(rendered).to have_unchecked_field('Render whitespace characters in the Web IDE')
    end

    it 'has an id for anchoring' do
      expect(rendered).to have_css('#behavior')
    end

    it 'has helpful homepage setup guidance' do
      expect(rendered).to have_selector('[data-label="Homepage"]')
      expect(rendered).to have_selector("[data-description=" \
                                        "'Choose what content you want to see by default on your homepage.']")
    end
  end

  describe 'localization' do
    before do
      render
    end

    it 'has an id for anchoring' do
      expect(rendered).to have_css('#localization')
    end
  end
end
