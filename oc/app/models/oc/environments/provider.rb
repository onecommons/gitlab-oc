# frozen_string_literal: true

module OC
  module Environments
    # OC Change -- the cloud account an environment deploys into.
    #
    # The fork used to keep this in a Kubernetes cluster record created with
    # platform_type: unfurl, which provisioned nothing: it was only ever a
    # per-environment credential. 19.3 deleted the pages and services that
    # wrote it, so it lives here instead.
    class Provider < ApplicationRecord
      self.table_name = 'oc_environment_providers'

      belongs_to :environment, class_name: '::Environment', inverse_of: :unfurl_provider
      belongs_to :project, class_name: '::Project'

      enum :provider, { aws: 1, gcp: 2 }

      encrypts :access_token

      validates :provider, presence: true
      # Rails' own recommendation for an encrypted column; a Google access
      # token is a few hundred characters.
      validates :access_token, length: { maximum: 2048 }

      with_options if: :aws? do
        validates :region, presence: true, length: { maximum: 255 }
        validates :role_arn, presence: true, length: { maximum: 2048 },
          format: { with: ::Gitlab::Regex.aws_arn_regex, message: ::Gitlab::Regex.aws_arn_regex_message }
        validates :role_external_ref, length: { maximum: 64 }
      end

      with_options if: :gcp? do
        validates :gcp_project, presence: true, length: { maximum: 63 }
        validates :zone, presence: true, length: { maximum: 255 }
      end

      validate :environment_within_project

      def access_token_usable?
        access_token.present? && access_token_expires_at.present? && access_token_expires_at.future?
      end

      # What a deployment job into this environment runs with. The AWS branch
      # assumes the role, so calling this costs a request to STS.
      def ci_variables
        ::Gitlab::Ci::Variables::Collection.new.tap do |variables|
          aws? ? append_aws_variables(variables) : append_gcp_variables(variables)
        end
      end

      private

      def append_aws_variables(variables)
        variables.append(key: 'AWS_DEFAULT_REGION', value: region)
        variables.append(key: 'AWS_ROLE_ARN', value: role_arn)

        session = AwsRoleCredentials.new(self).credentials
        variables.append(key: 'AWS_ACCESS_KEY_ID', value: session.access_key_id, public: false)
        variables.append(key: 'AWS_SECRET_ACCESS_KEY', value: session.secret_access_key, public: false, masked: true)
        variables.append(key: 'AWS_SESSION_TOKEN', value: session.session_token, public: false, masked: true)
      end

      def append_gcp_variables(variables)
        variables.append(key: 'CLOUDSDK_CORE_PROJECT', value: gcp_project)
        variables.append(key: 'CLOUDSDK_COMPUTE_ZONE', value: zone)

        # Expires an hour after the sign-in. Unfurl's gcp configurator spends it
        # once, creating a service account that everything afterwards uses, so a
        # job that starts too late is better off without it than with a token
        # the API will reject.
        return unless access_token_usable?

        variables.append(key: 'GOOGLE_OAUTH_ACCESS_TOKEN', value: access_token, public: false, masked: true)
      end

      def environment_within_project
        return if environment.nil? || project_id.nil? || environment.project_id == project_id

        errors.add(:environment, _('must belong to the same project'))
      end
    end
  end
end
