# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'A dashboard project', feature_category: :groups_and_projects do
  let(:user) { create(:user, :with_namespace) }
  let(:project) { create(:project, :repository, :private, namespace: user.namespace) }

  before do
    sign_in(user)
  end

  it 'renders the dashboard app with the data the package reads' do
    project.custom_attributes.create!(key: 'unfurl_type', value: OC::UNFURL_DASHBOARD)

    get project_path(project)

    expect(response).to have_gitlab_http_status(:ok)
    expect(response.body).to include('js-table-component')
    expect(response.body).to include(project.full_path)
  end

  it 'leaves an ordinary project on the repository page' do
    project.custom_attributes.create!(key: 'unfurl_type', value: OC::REGULAR_PROJECT)

    get project_path(project)

    expect(response).to have_gitlab_http_status(:ok)
    expect(response.body).not_to include('js-table-component')
  end

  it 'does not classify while rendering' do
    expect { get project_path(project) }.not_to change { project.custom_attributes.count }
  end
end
