# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Project blueprint overview', feature_category: :source_code_management do
  let_it_be(:project) { create(:project, :public, :repository) }

  def mount_point
    Nokogiri::HTML(response.body).at_css('#js-oc-project-overview')
  end

  describe 'GET /:namespace/:project/-/overview' do
    it 'renders the oc-pages mount point for an anonymous visitor' do
      get project_overview_path(project)

      expect(response).to have_gitlab_http_status(:ok)
      expect(mount_point['data-project-path']).to eq(project.full_path)
      expect(mount_point['data-ref']).to eq(project.default_branch)
      expect(mount_point['data-readme-raw']).to eq(project.repository.readme.data)
    end

    it 'serves the same page under a client-side route' do
      get project_overview_path(project, vueroute: 'deployment-drafts/example')

      expect(response).to have_gitlab_http_status(:ok)
      expect(mount_point).to be_present
    end

    it 'renders the README, which oc-pages puts through v-html' do
      get project_overview_path(project)

      expect(mount_point['data-readme']).to include('<')
      expect(mount_point['data-readme']).not_to eq(project.repository.readme.data)
    end

    # oc-pages reads this img's src, so a lazy-loaded one -- which never resolves
    # inside a hidden element -- leaves the page's hero empty.
    it 'gives a project with no avatar the Unfurl placeholder, not an identicon' do
      get project_overview_path(project)

      icon = Nokogiri::HTML(response.body).at_css('#oc-project-overview-icon img')
      expect(icon['src']).to match(%r{/-/oc/assets/images/uf-avatar-placeholder-\d\.svg})
    end

    it "serves a project's own avatar from the same place" do
      avatared = create(:project, :public, :repository,
        avatar: fixture_file_upload('spec/fixtures/dk.png', 'image/png'))

      get project_overview_path(avatared)

      icon = Nokogiri::HTML(response.body).at_css('#oc-project-overview-icon img')
      expect(icon['src']).to eq(avatared.avatar_url)
    end

    it 'leaves the README out when the visitor cannot read code' do
      get project_overview_path(create(:project, :public, :repository, :repository_private))

      expect(response).to have_gitlab_http_status(:ok)
      expect(mount_point).to be_present
      expect(mount_point['data-readme-raw']).to be_nil
    end

    it 'is not found on a project the user cannot see' do
      sign_in(create(:user))

      get project_overview_path(create(:project, :private, :repository))

      expect(response).to have_gitlab_http_status(:not_found)
    end

    it 'passes the Unfurl server URL to the browser when one is configured' do
      stub_config(extra: { unfurl_server_url: 'https://unfurl.example.com' })

      get project_overview_path(project)

      expect(response.body).to include('gon.unfurl_server_url="https://unfurl.example.com"')
    end

    it 'leaves the Unfurl server URL out when none is configured' do
      stub_config(extra: {})

      get project_overview_path(project)

      expect(response.body).not_to include('gon.unfurl_server_url')
    end
  end

  describe 'GET /:namespace/:project' do
    let_it_be(:blueprint) do
      create(:project, :public, :repository).tap do |blueprint|
        blueprint.custom_attributes.create!(key: 'unfurl_type', value: OC::UNFURL_BLUEPRINT)
      end
    end

    it 'renders the overview from the blueprint project itself' do
      get project_path(blueprint)

      expect(response).to have_gitlab_http_status(:ok)
      expect(mount_point['data-project-path']).to eq(blueprint.full_path)
    end

    it 'leaves an ordinary project on its repository landing page' do
      get project_path(project)

      expect(response).to have_gitlab_http_status(:ok)
      expect(mount_point).to be_nil
    end

    it 'renders it for a client that sends no Accept but */*' do
      get project_path(blueprint), headers: { 'Accept' => '*/*' }

      expect(response).to have_gitlab_http_status(:ok)
      expect(mount_point).to be_present
    end

    it 'still answers the atom feed, which is not a page at all' do
      get project_path(blueprint, format: :atom)

      expect(response).to have_gitlab_http_status(:ok)
      expect(response.media_type).to eq('application/atom+xml')
    end
  end
end
