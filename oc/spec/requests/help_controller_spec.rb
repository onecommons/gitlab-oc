# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Help pages from oc/doc', feature_category: :source_code_management do
  let_it_be(:user) { create(:user) }

  before do
    sign_in(user)
  end

  context 'when help pages are rendered locally' do
    before do
      stub_application_setting(help_page_documentation_base_url: '')
    end

    it 'serves a page that only the fork has' do
      get help_page_path('user/project/work_items_sync.md')

      expect(response).to have_gitlab_http_status(:ok)
      expect(response.body).to include('Work items sync')
      expect(response.body).to include('gitlab-work-items')
    end

    it 'still serves upstream pages' do
      get help_page_path('user/project/repository/mirror/_index.md')

      expect(response).to have_gitlab_http_status(:ok)
      expect(response.body).to include('mirror')
    end
  end

  # The default, and docs.gitlab.com has no copy of a fork page, so the
  # redirect must leave those alone and only those.
  context 'when help pages redirect to an external documentation site' do
    before do
      stub_application_setting(help_page_documentation_base_url: 'https://docs.example.com')
    end

    it 'renders a fork page locally' do
      get help_page_path('user/project/work_items_sync.md')

      expect(response).to have_gitlab_http_status(:ok)
      expect(response.body).to include('gitlab-work-items')
    end

    it 'redirects an upstream page' do
      get help_page_path('user/project/repository/mirror/_index.md')

      expect(response).to redirect_to(%r{\Ahttps://docs.example.com/})
    end
  end
end
