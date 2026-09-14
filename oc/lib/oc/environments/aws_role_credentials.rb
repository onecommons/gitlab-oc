# frozen_string_literal: true

module OC
  module Environments
    # Assumes an environment's deploy role, for the credentials its jobs run
    # with. A plain object rather than a service so the provider model may call
    # it: CodeReuse/ServiceClass forbids a Service class in a model.
    #
    # Ported from 15.11's Clusters::Aws::FetchCredentialsService without its
    # read-only-policy branch, which existed to hand credentials to the browser.
    # Nothing does that now.
    class AwsRoleCredentials
      def initialize(provider)
        @provider = provider
      end

      def credentials
        ::Aws::AssumeRoleCredentials.new(
          client: client,
          role_arn: provider.role_arn,
          role_session_name: session_name,
          external_id: provider.role_external_ref
        ).credentials
      end

      private

      attr_reader :provider

      def client
        ::Aws::STS::Client.new(**{ region: provider.region, credentials: instance_credentials }.compact)
      end

      # Nil when the instance runs under an IAM instance profile, which the SDK
      # then finds for itself.
      def instance_credentials
        key_id = ::Gitlab::CurrentSettings.eks_access_key_id
        secret = ::Gitlab::CurrentSettings.eks_secret_access_key
        return if key_id.blank? || secret.blank?

        ::Aws::Credentials.new(key_id, secret)
      end

      def session_name
        "unfurl-environment-#{provider.environment_id}"
      end
    end
  end
end
