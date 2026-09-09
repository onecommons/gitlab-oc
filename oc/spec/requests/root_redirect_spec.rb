# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Signed-in landing page', feature_category: :groups_and_projects do
  let(:user) { create(:user, :with_namespace) }
  let(:dashboard) { create(:project, namespace: user.namespace) }

  before do
    sign_in(user)
  end

  it 'lands on the dashboard project' do
    dashboard.custom_attributes.create!(key: 'unfurl_type', value: OC::UNFURL_DASHBOARD)
    dashboard.add_maintainer(user)

    get '/'

    expect(response).to redirect_to(project_path(dashboard))
  end

  it 'offers to create a dashboard when there is none' do
    get '/'

    expect(response).to redirect_to(new_project_path)
    expect(flash[:alert]).to include('do not have a dashboard project')
  end
end
