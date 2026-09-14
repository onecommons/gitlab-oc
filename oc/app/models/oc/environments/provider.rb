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

      private

      def environment_within_project
        return if environment.nil? || project_id.nil? || environment.project_id == project_id

        errors.add(:environment, _('must belong to the same project'))
      end
    end
  end
end
