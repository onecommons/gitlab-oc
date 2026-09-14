# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Environment cloud providers', feature_category: :continuous_delivery do
  # Refound per example: Warden's test mode hands the controller this very
  # object on every request, so an aws_role cached on it by one example would
  # otherwise outlive the row's rollback.
  let_it_be_with_refind(:maintainer) { create(:user, :with_namespace) }
  let_it_be(:developer) { create(:user, :with_namespace) }

  let_it_be(:dashboard) do
    create(:project, :repository).tap do |project|
      project.record_unfurl_type!(OC::UNFURL_DASHBOARD)
      project.add_maintainer(maintainer)
      project.add_developer(developer)
    end
  end

  let_it_be(:environment) { create(:environment, project: dashboard, name: 'production') }

  let(:base) { project_environment_provider_path(dashboard, environment_id: environment.name) }

  let(:sts) { Aws::STS::Client.new(stub_responses: true, region: 'us-east-2') }

  before do
    allow(Aws::STS::Client).to receive(:new).and_return(sts)
    sts.stub_responses(:assume_role, credentials: {
      access_key_id: 'ASIAEXAMPLE', secret_access_key: 'secret', session_token: 'token',
      expiration: 1.hour.from_now
    })

    sign_in(maintainer)
  end

  def sign_in_to_google(expires_at: 1.hour.from_now)
    # What upstream's OAuth callback leaves behind: epoch seconds, as a string.
    allow_next_instance_of(Projects::EnvironmentProvidersController) do |controller|
      allow(controller).to receive(:session).and_wrap_original do |original|
        original.call.tap do |session|
          session[GoogleApi::CloudPlatform::Client.session_key_for_token] = 'ya29.signed-in'
          session[GoogleApi::CloudPlatform::Client.session_key_for_expires_at] = expires_at.to_i.to_s
        end
      end
    end
  end

  describe 'GET provider' do
    it 'is 404 until the environment has one' do
      get base

      expect(response).to have_gitlab_http_status(:not_found)
    end

    it 'describes the provider without handing back a credential' do
      create(:oc_environment_provider, :gcp, environment: environment)

      get base

      expect(response).to have_gitlab_http_status(:ok)
      expect(json_response).to eq(
        'provider' => 'gcp', 'region' => nil, 'zone' => 'us-central1-a',
        'gcp_project_id' => 'unfurl-example', 'role_arn' => nil, 'access_token_usable' => true
      )
      expect(response.body).not_to include('ya29')
    end

    it 'finds the environment by id as well as by name' do
      create(:oc_environment_provider, environment: environment)

      get project_environment_provider_path(dashboard, environment_id: environment.id)

      expect(response).to have_gitlab_http_status(:ok)
    end
  end

  describe 'PUT provider, aws' do
    let(:params) { { provider: 'aws', region: 'us-east-2', role_arn: 'arn:aws:iam::123456789012:role/Deploy' } }

    it 'assumes the role before saving it' do
      put base, params: params

      expect(response).to have_gitlab_http_status(:ok)
      expect(json_response).to include('provider' => 'aws', 'role_arn' => params[:role_arn])

      provider = environment.reload.unfurl_provider
      expect(provider.role_external_ref).to eq(maintainer.reload.aws_role.role_external_id)
      expect(sts.api_requests.first[:params][:external_id]).to eq(provider.role_external_ref)
    end

    it 'reports what AWS said when the role does not trust this instance' do
      sts.stub_responses(:assume_role, 'AccessDenied')

      put base, params: params

      expect(response).to have_gitlab_http_status(:unprocessable_entity)
      expect(json_response['message']).to be_present
      expect(environment.reload.unfurl_provider).to be_nil
    end

    it 'reports a timeout reaching AWS rather than failing the request' do
      allow(Aws::AssumeRoleCredentials).to receive(:new).and_raise(
        Seahorse::Client::NetworkingError.new(Timeout::Error.new)
      )

      put base, params: params

      expect(response).to have_gitlab_http_status(:unprocessable_entity)
      expect(json_response['message']).to be_present
    end

    it 'rejects a malformed role arn without calling AWS' do
      put base, params: params.merge(role_arn: 'not-an-arn')

      expect(response).to have_gitlab_http_status(:unprocessable_entity)
      expect(sts.api_requests).to be_empty
    end

    it 'replaces a provider the environment already has' do
      create(:oc_environment_provider, :gcp, environment: environment)

      put base, params: params

      provider = environment.reload.unfurl_provider
      expect(provider).to be_aws
      expect(provider.gcp_project).to be_nil
      expect(provider.access_token).to be_nil
    end
  end

  describe 'PUT provider, gcp' do
    let(:params) { { provider: 'gcp', gcp_project_id: 'unfurl-demo', zone: 'us-central1-a' } }

    it 'stores the project, the zone and the token from the sign-in' do
      sign_in_to_google

      put base, params: params

      expect(response).to have_gitlab_http_status(:ok)
      expect(json_response).to include('gcp_project_id' => 'unfurl-demo', 'access_token_usable' => true)
      expect(environment.reload.unfurl_provider.access_token).to eq('ya29.signed-in')
    end

    it 'asks for a sign-in when the session carries no token' do
      put base, params: params

      expect(response).to have_gitlab_http_status(:unprocessable_entity)
      expect(environment.reload.unfurl_provider).to be_nil
    end

    it 'asks for a sign-in when the token has too little life left' do
      sign_in_to_google(expires_at: 1.minute.from_now)

      put base, params: params

      expect(response).to have_gitlab_http_status(:unprocessable_entity)
    end
  end

  describe 'DELETE provider' do
    it 'removes it, and takes a second delete as a no-op' do
      create(:oc_environment_provider, environment: environment)

      delete base

      expect(response).to have_gitlab_http_status(:no_content)
      expect(environment.reload.unfurl_provider).to be_nil

      delete base

      expect(response).to have_gitlab_http_status(:no_content)
    end
  end

  describe 'GET provider/aws/role' do
    it 'creates the external id on first call and keeps it afterwards' do
      get project_environment_provider_aws_role_path(dashboard, environment_id: environment.name)

      expect(response).to have_gitlab_http_status(:ok)
      external_id = json_response['external_id']
      expect(external_id).to be_present
      expect(json_response).to have_key('account_id')

      get project_environment_provider_aws_role_path(dashboard, environment_id: environment.name)

      expect(json_response['external_id']).to eq(external_id)
    end
  end

  describe 'GET provider/gcp/authorize' do
    def authorize(return_to)
      get project_environment_provider_gcp_authorize_path(
        dashboard, environment_id: environment.name, return_to: return_to
      )
    end

    before do
      stub_omniauth_setting(enabled: true)
      allow(Gitlab::Auth::OAuth::Provider).to receive(:config_for).with('google_oauth2').and_return(
        Struct.new(:app_id, :app_secret, :args).new(
          'id', 'secret', ActiveSupport::InheritableOptions.new(client_options: {})
        )
      )
    end

    it 'sends the user to Google and remembers where to come back to' do
      authorize('/group/dashboard/-/environments/production?provider=gcp')

      expect(response).to have_gitlab_http_status(:found)
      expect(response.location).to start_with('https://accounts.google.com/o/oauth2/auth')
      expect(response.location).to include('cloudplatformprojects').and include('iam')
    end

    it 'refuses a return path on another origin' do
      authorize('https://evil.example.com/')

      expect(response).to have_gitlab_http_status(:unprocessable_entity)
    end

    it 'says so when the instance has no Google application configured' do
      allow(Gitlab::Auth::OAuth::Provider).to receive(:config_for).with('google_oauth2').and_return(nil)

      authorize('/group/dashboard/-/environments/production')

      expect(response).to have_gitlab_http_status(:unprocessable_entity)
    end
  end

  describe 'GET provider/gcp/projects' do
    let(:path) { project_environment_provider_gcp_projects_path(dashboard, environment_id: environment.name) }

    it 'lists the signed-in account projects' do
      sign_in_to_google
      allow_next_instance_of(OC::Environments::GoogleCloudClient) do |client|
        allow(client).to receive(:list_projects).and_return(
          [instance_double(Google::Apis::CloudresourcemanagerV1::Project, project_id: 'p-1', name: 'Demo')]
        )
      end

      get path

      expect(response).to have_gitlab_http_status(:ok)
      expect(json_response).to eq([{ 'project_id' => 'p-1', 'name' => 'Demo' }])
    end

    it 'asks for a sign-in without a token' do
      get path

      expect(response).to have_gitlab_http_status(:unprocessable_entity)
    end
  end

  describe 'authorization' do
    it 'refuses a developer' do
      sign_in(developer)

      get base

      expect(response).to have_gitlab_http_status(:forbidden)
    end

    it 'refuses an anonymous visitor' do
      sign_out(maintainer)

      get base

      expect(response).to have_gitlab_http_status(:found)
    end

    it 'is 404 on a project that is not a dashboard' do
      plain = create(:project, :repository).tap { |project| project.add_maintainer(maintainer) }
      plain_environment = create(:environment, project: plain)

      get project_environment_provider_path(plain, environment_id: plain_environment.name)

      expect(response).to have_gitlab_http_status(:not_found)
    end
  end
end
