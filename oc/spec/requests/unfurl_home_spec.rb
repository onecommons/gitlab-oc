# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Dashboard home routes', feature_category: :groups_and_projects do
  let(:user) { create(:user, :with_namespace) }
  let(:dashboard) { create(:project, namespace: user.namespace) }

  def classify_dashboard
    dashboard.custom_attributes.create!(key: 'unfurl_type', value: OC::UNFURL_DASHBOARD)
    dashboard.add_maintainer(user)
  end

  it 'sends an anonymous visitor to sign in' do
    get '/home'

    expect(response).to redirect_to(new_user_session_path)
  end

  context 'when signed in' do
    before do
      sign_in(user)
    end

    it 'redirects to the dashboard project' do
      classify_dashboard

      get '/home'

      expect(response).to redirect_to(project_path(dashboard))
    end

    it 'looks a dashboard up by username' do
      classify_dashboard

      get "/home/#{user.username}"

      expect(response).to redirect_to(project_path(dashboard))
    end

    it 'offers to create one when the user has no dashboard' do
      get '/home'

      expect(response).to redirect_to(new_project_path)
      expect(flash[:alert]).to include('do not have a dashboard project')
    end
  end
end
