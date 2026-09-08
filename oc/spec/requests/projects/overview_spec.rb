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
end
