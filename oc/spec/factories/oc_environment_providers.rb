# frozen_string_literal: true

FactoryBot.define do
  factory :oc_environment_provider, class: 'OC::Environments::Provider' do
    environment
    project { environment.project }
    provider { :aws }
    region { 'us-east-2' }
    role_arn { 'arn:aws:iam::123456789012:role/UnfurlDeployRole' }
    role_external_ref { SecureRandom.hex(20) }

    trait :gcp do
      provider { :gcp }
      region { nil }
      role_arn { nil }
      role_external_ref { nil }
      gcp_project { 'unfurl-example' }
      zone { 'us-central1-a' }
      access_token { 'ya29.example-token' }
      access_token_expires_at { 1.hour.from_now }
    end

    trait :expired_token do
      access_token_expires_at { 1.hour.ago }
    end
  end
end
