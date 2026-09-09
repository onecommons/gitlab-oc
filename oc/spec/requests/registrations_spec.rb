# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Signing up', :with_current_organization, feature_category: :system_access do
  let(:attributes) { build_stubbed(:user).slice(:first_name, :last_name, :username, :email, :password) }

  before do
    # Unfurl Cloud signs users in straight away; with confirmation on, devise
    # sends them to the sign-in page instead and after_sign_up_path never runs.
    stub_application_setting_enum('email_confirmation_setting', 'off')
    stub_application_setting(require_admin_approval_after_user_signup: false)
  end

  def sign_up(extra = {})
    post user_registration_path, params: { user: attributes.merge(extra) }
  end

  def created_user
    User.find_by(username: attributes[:username])
  end

  it 'offers the interface choice and a slot for the invite code' do
    get new_user_registration_path

    expect(response.body).to include('oc_interface')
    expect(response.body).to include('js-oc-invite-code')
  end

  it 'asks for a first name only' do
    post user_registration_path, params: { user: attributes.merge(last_name: '') }

    expect(created_user).to be_present

    nameless = attributes.merge(username: 'nameless', email: 'n@example.org', first_name: '')
    post user_registration_path, params: { user: nameless }

    expect(User.find_by(username: 'nameless')).to be_nil
  end

  it 'lands the new user on their dashboard' do
    sign_up

    expect(response).to redirect_to(unfurl_home_index_path)
    expect(created_user).to be_present
  end

  # Out of the request: creating it inline costs about 120 SQL queries and a
  # controller action is held to 100.
  it 'creates the dashboard project in the background' do
    expect { sign_up }.to change { OC::Onboarding::CreateDashboardProjectWorker.jobs.size }.by(1)

    OC::Onboarding::CreateDashboardProjectWorker.drain

    expect(created_user.projects.find_by(path: OC::UNFURL_DASHBOARD_NAME)).to be_present
  end

  describe 'the interface choice' do
    it 'makes a deploying user external' do
      sign_up(oc_interface: 'deploy')

      expect(created_user).to be_external
    end

    it 'leaves a developing user alone' do
      sign_up(oc_interface: 'develop')

      expect(created_user).not_to be_external
    end
  end

  describe 'invite codes' do
    it 'records one that we issued' do
      create(:ci_instance_variable, key: OC::Onboarding::InviteCodes::VALID_KEY, value: 'alpha, beta')

      sign_up(invite_code: 'beta')

      expect(created_user.custom_attributes.find_by(key: 'invite_code')&.value).to eq('beta')
    end

    it 'refuses one we did not, without creating the user' do
      create(:ci_instance_variable, key: OC::Onboarding::InviteCodes::VALID_KEY, value: 'alpha')

      sign_up(invite_code: 'not-ours')

      expect(response).to have_gitlab_http_status(:ok)
      expect(flash[:alert]).to eq('Invite code is invalid.')
      expect(created_user).to be_nil
    end

    it 'lets an approving code past the admin approval the instance requires' do
      stub_application_setting(require_admin_approval_after_user_signup: true)
      create(:ci_instance_variable, key: OC::Onboarding::InviteCodes::VALID_KEY, value: 'friend-1')
      create(:ci_instance_variable, key: OC::Onboarding::InviteCodes::APPROVE_KEY, value: '\\Afriend-')

      sign_up(invite_code: 'friend-1')

      expect(created_user).not_to be_blocked_pending_approval
      expect(response).to redirect_to(unfurl_home_index_path)
    end

    it 'still blocks a merely valid code when the instance requires approval' do
      stub_application_setting(require_admin_approval_after_user_signup: true)
      create(:ci_instance_variable, key: OC::Onboarding::InviteCodes::VALID_KEY, value: 'friend-1')

      sign_up(invite_code: 'friend-1')

      expect(created_user).to be_blocked_pending_approval
    end

    it 'accepts a signup with no code at all' do
      sign_up

      expect(created_user).to be_present
      expect(created_user.custom_attributes.find_by(key: 'invite_code')).to be_nil
    end
  end
end
