# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'A dashboard project\'s own pages', feature_category: :continuous_delivery do
  let(:user) { create(:user, :with_namespace) }
  let(:project) { create(:project, :repository, :private, namespace: user.namespace) }
  let(:environment) { create(:environment, project: project, name: 'production') }

  before do
    sign_in(user)
  end

  def classify(type)
    project.custom_attributes.create!(key: 'unfurl_type', value: type)
  end

  context 'when the project is a dashboard' do
    before do
      classify(OC::UNFURL_DASHBOARD)
    end

    it 'shows the dashboard app instead of the environments list' do
      get project_environments_path(project)

      expect(response).to have_gitlab_http_status(:ok)
      expect(response.body).to include('js-table-component')
    end

    it 'serves its own deployments page, and every client-side route under it' do
      get project_unfurl_deployments_path(project)
      expect(response).to have_gitlab_http_status(:ok)
      expect(response.body).to include('js-table-component')

      get "#{project_unfurl_deployments_path(project)}/production/some-deployment"
      expect(response).to have_gitlab_http_status(:ok)
    end

    it 'serves the applications view the same way' do
      get project_unfurl_applications_path(project)

      expect(response).to have_gitlab_http_status(:ok)
      expect(response.body).to include('js-table-component')
    end

    # The bundler builds an entry name from the controller path, so the
    # environments controller has its own door into the same app.
    it 'asks for a dashboard bundle whichever view rendered it' do
      {
        project_path(project) => 'pages.projects.oc_dashboard',
        project_unfurl_deployments_path(project) => 'pages.projects.oc_dashboard',
        project_unfurl_applications_path(project) => 'pages.projects.oc_dashboard',
        project_environments_path(project) => 'pages.projects.environments.oc_dashboard'
      }.each do |path, bundle|
        get path

        expect(response.body).to include(bundle), "#{path} did not ask for #{bundle}"
      end
    end

    it 'finds an environment by name, which the dashboard links by' do
      get project_environment_path(project, environment.name)

      expect(response).to have_gitlab_http_status(:ok)
      expect(response.body).to include('js-table-component')
    end

    # The dashboard replaces the HTML view only. oc-pages' delete flow reads
    # this endpoint, so the guard that lets JSON through is worth pinning.
    it 'passes the environments list through as JSON' do
      get project_environments_path(project, format: :json)

      expect(response).to have_gitlab_http_status(:ok)
      expect(json_response).to have_key('environments')
      expect(response.body).not_to include('js-table-component')
    end

    describe 'the environment page cloud provider box' do
      it 'carries the provider the environment deploys into' do
        create(:oc_environment_provider, :gcp, environment: environment, gcp_project: 'unfurl-demo')

        get project_environment_path(project, environment.name)

        expect(response.body).to include('js-oc-ci-variables')
        expect(response.body).to include('unfurl-demo').and include('us-central1-a')
      end

      it 'falls back to the environment variables the key-upload method writes' do
        create(:ci_variable, project: project, key: 'CLOUDSDK_CORE_PROJECT',
          value: 'from-key-file', environment_scope: environment.name)

        get project_environment_path(project, environment.name)

        expect(response.body).to include('from-key-file')
      end

      it 'is absent from a page that is not about one environment' do
        get project_unfurl_deployments_path(project)

        expect(response.body).not_to include('js-oc-ci-variables')
      end
    end
  end

  context 'when it is an ordinary project' do
    before do
      classify(OC::REGULAR_PROJECT)
    end

    it 'leaves the environments list alone' do
      get project_environments_path(project)

      expect(response).to have_gitlab_http_status(:ok)
      expect(response.body).not_to include('js-table-component')
    end

    it 'has no deployments page of its own' do
      get project_unfurl_deployments_path(project)

      expect(response).to have_gitlab_http_status(:not_found)
    end

    it 'still looks environments up by id only' do
      get project_environment_path(project, environment.name)

      expect(response).to have_gitlab_http_status(:not_found)
    end
  end
end
