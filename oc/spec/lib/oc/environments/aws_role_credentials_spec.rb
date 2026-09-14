# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OC::Environments::AwsRoleCredentials, feature_category: :continuous_delivery do
  let_it_be(:environment) { create(:environment) }
  let(:provider) { create(:oc_environment_provider, environment: environment, region: 'eu-west-1') }
  let(:sts) { Aws::STS::Client.new(stub_responses: true, region: 'eu-west-1') }

  before do
    allow(Aws::STS::Client).to receive(:new).and_return(sts)
    sts.stub_responses(:assume_role, credentials: {
      access_key_id: 'ASIAEXAMPLE', secret_access_key: 'secret', session_token: 'token',
      expiration: 1.hour.from_now
    })
  end

  it 'assumes the role the environment names, with the external id AWS expects' do
    expect(described_class.new(provider).credentials.access_key_id).to eq('ASIAEXAMPLE')

    request = sts.api_requests.first[:params]
    expect(request[:role_arn]).to eq(provider.role_arn)
    expect(request[:external_id]).to eq(provider.role_external_ref)
    expect(request[:role_session_name]).to eq("unfurl-environment-#{environment.id}")
  end

  context 'with the instance EKS keys configured' do
    before do
      stub_application_setting(eks_access_key_id: 'AKIAINSTANCE', eks_secret_access_key: 'instance-secret')
    end

    it 'calls STS as the instance, in the provider region' do
      described_class.new(provider).credentials

      expect(Aws::STS::Client).to have_received(:new) do |args|
        expect(args[:region]).to eq('eu-west-1')
        expect(args[:credentials].access_key_id).to eq('AKIAINSTANCE')
      end
    end
  end

  context 'without the instance EKS keys' do
    it 'leaves the SDK to find credentials, for an instance profile' do
      described_class.new(provider).credentials

      expect(Aws::STS::Client).to have_received(:new) do |args|
        expect(args).not_to have_key(:credentials)
      end
    end
  end
end
