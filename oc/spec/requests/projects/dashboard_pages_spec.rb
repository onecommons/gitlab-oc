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

    it 'finds an environment by name, which the dashboard links by' do
      get project_environment_path(project, environment.name)

      expect(response).to have_gitlab_http_status(:ok)
      expect(response.body).to include('js-table-component')
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

    it 'still looks environments up by id only' do
      get project_environment_path(project, environment.name)

      expect(response).to have_gitlab_http_status(:not_found)
    end
  end
end
