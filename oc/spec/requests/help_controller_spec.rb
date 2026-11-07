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
      expect(response.body).to include('work-items-sync')
    end

    it 'serves the fork help landing page, with its guides and contact footer' do
      get help_path

      expect(response).to have_gitlab_http_status(:ok)
      expect(response.body).to include('Help Center')
      # The two getting-started tiles, from oc/doc/guides.
      expect(response.body).to include('Google Cloud Platform').and include('Amazon Web Services')
      # docs_bundle binds Mousetrap to these without a null check; dropping
      # them makes the page raise on load.
      expect(response.body).to include('js-trigger-search-bar').and include('js-trigger-shortcut')
    end

    it 'serves a guide the landing page links to' do
      get help_page_path('guides/getting_started_gcp.md')

      expect(response).to have_gitlab_http_status(:ok)
    end

    it "shows upstream's documentation index at /help/docs, rather than docs.gitlab.com" do
      get help_docs_path

      expect(response).to have_gitlab_http_status(:ok)
      expect(response.body).to include('Use GitLab')
    end

    # Upstream serves the other doc/ image types; the diagrams are SVG.
    it 'serves a doc/ SVG without letting it run script' do
      get '/help/user/application_security/secret_detection/secret_push_protection/img/spp_workflow_v17_9.drawio.svg'

      expect(response).to have_gitlab_http_status(:ok)
      expect(response.media_type).to eq('image/svg+xml')
      expect(response.headers['Content-Disposition']).to start_with('inline')
      expect(response.headers['Content-Security-Policy']).to start_with("default-src 'none'")
    end

    it 'drops a trailing slash, which would break the page\'s relative links' do
      get "#{help_page_path('user/project/work_items_sync.md')}/"

      expect(response).to redirect_to(help_page_path('user/project/work_items_sync.md'))
      expect(response).to have_gitlab_http_status(:moved_permanently)
    end

    it 'keeps SVG requests inside doc/' do
      get '/help/foo/bar.svg'
      expect(response).to have_gitlab_http_status(:not_found)

      # GitLab's path traversal check answers this one before the controller.
      get '/help/../app/assets/images/logo.svg'
      expect(response).not_to have_gitlab_http_status(:ok)
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
      expect(response.body).to include('work-items-sync')
    end

    it 'redirects an upstream page' do
      get help_page_path('user/project/repository/mirror/_index.md')

      expect(response).to redirect_to(%r{\Ahttps://docs.example.com/})
    end

    it 'sends /help/docs there too' do
      get help_docs_path

      expect(response).to redirect_to('https://docs.example.com')
    end
  end
end
