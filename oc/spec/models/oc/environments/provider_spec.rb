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
