# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OC::Environments::Provider, feature_category: :continuous_delivery do
  let_it_be(:project) { create(:project) }
  let_it_be(:environment) { create(:environment, project: project) }

  describe 'associations and validations' do
    it { is_expected.to belong_to(:environment) }
    it { is_expected.to belong_to(:project) }

    it 'is valid with the aws defaults' do
      expect(build(:oc_environment_provider, environment: environment)).to be_valid
    end

    it 'is valid with the gcp defaults' do
      expect(build(:oc_environment_provider, :gcp, environment: environment)).to be_valid
    end

    it 'requires a region and a well-formed role arn for aws' do
      provider = build(:oc_environment_provider, environment: environment, region: nil, role_arn: 'not-an-arn')

      expect(provider).not_to be_valid
      expect(provider.errors.attribute_names).to include(:region, :role_arn)
    end

    it 'requires a project and a zone for gcp' do
      provider = build(:oc_environment_provider, :gcp, environment: environment, gcp_project: nil, zone: nil)

      expect(provider).not_to be_valid
      expect(provider.errors.attribute_names).to include(:gcp_project, :zone)
    end

    it 'does not ask an aws row for gcp attributes' do
      expect(build(:oc_environment_provider, environment: environment, gcp_project: nil, zone: nil)).to be_valid
    end

    it 'rejects an environment from another project' do
      provider = build(:oc_environment_provider, environment: create(:environment), project: project)

      expect(provider).not_to be_valid
      expect(provider.errors.attribute_names).to include(:environment)
    end

    it 'allows one provider per environment' do
      create(:oc_environment_provider, environment: environment)

      expect { create(:oc_environment_provider, environment: environment) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe 'the access token' do
    it 'round-trips without storing the plaintext' do
      provider = create(:oc_environment_provider, :gcp, environment: environment, access_token: 'ya29.secret')

      expect(provider.reload.access_token).to eq('ya29.secret')
      expect(described_class.connection.select_value(
        "SELECT access_token FROM oc_environment_providers WHERE id = #{provider.id}"
      )).not_to include('ya29.secret')
    end
  end

  describe '#ci_variables' do
    def values(provider)
      provider.ci_variables.to_hash
    end

    context 'with aws' do
      let(:provider) { create(:oc_environment_provider, environment: environment, region: 'eu-west-1') }
      let(:sts) { Aws::STS::Client.new(stub_responses: true, region: 'eu-west-1') }

      before do
        allow(Aws::STS::Client).to receive(:new).and_return(sts)
        sts.stub_responses(:assume_role, credentials: {
          access_key_id: 'ASIAEXAMPLE', secret_access_key: 'secret', session_token: 'token',
          expiration: 1.hour.from_now
        })
      end

      it 'hands the job the region, the role and a session assumed for it' do
        expect(values(provider)).to include(
          'AWS_DEFAULT_REGION' => 'eu-west-1',
          'AWS_ROLE_ARN' => provider.role_arn,
          'AWS_ACCESS_KEY_ID' => 'ASIAEXAMPLE',
          'AWS_SECRET_ACCESS_KEY' => 'secret',
          'AWS_SESSION_TOKEN' => 'token'
        )
      end

      it 'keeps the session out of the job log and out of the exposed variables' do
        variables = provider.ci_variables

        expect(variables.reject { |item| item[:public] }.map(&:key))
          .to contain_exactly('AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_SESSION_TOKEN')
        expect(variables.select(&:masked?).map(&:key))
          .to contain_exactly('AWS_SECRET_ACCESS_KEY', 'AWS_SESSION_TOKEN')
      end
    end

    context 'with gcp' do
      let(:provider) { create(:oc_environment_provider, :gcp, environment: environment) }

      it 'hands the job the project, the zone and the sign-in token' do
        expect(values(provider)).to eq(
          'CLOUDSDK_CORE_PROJECT' => 'unfurl-example',
          'CLOUDSDK_COMPUTE_ZONE' => 'us-central1-a',
          'GOOGLE_OAUTH_ACCESS_TOKEN' => 'ya29.example-token'
        )
      end

      it 'leaves out a token that has expired' do
        provider.update!(access_token_expires_at: 1.hour.ago)

        expect(values(provider).keys).not_to include('GOOGLE_OAUTH_ACCESS_TOKEN')
      end
    end
  end

  describe '#access_token_usable?' do
    it 'is true for a token that has not expired' do
      expect(build(:oc_environment_provider, :gcp, environment: environment)).to be_access_token_usable
    end

    it 'is false once the token has expired' do
      expect(build(:oc_environment_provider, :gcp, :expired_token, environment: environment))
        .not_to be_access_token_usable
    end

    it 'is false without a token' do
      expect(build(:oc_environment_provider, environment: environment)).not_to be_access_token_usable
    end
  end
end
