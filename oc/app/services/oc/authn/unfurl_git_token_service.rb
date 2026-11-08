# frozen_string_literal: true

module OC
  module Authn
    # OC Change -- the git token a user hands the Unfurl server, so a
    # deployment can push its results back. One per user, kept encrypted in
    # OC::Authn::UnfurlGitToken and reused while it is active; an inactive one
    # is replaced and its token deleted, since nothing cleans up people's
    # expired tokens.
    class UnfurlGitTokenService
      include ::Gitlab::ExclusiveLeaseHelpers

      TOKEN_SCOPES = %w[read_repository write_repository].freeze
      TOKEN_LIFETIME = 7.days

      def self.for_user(user, organization_id:)
        new(user, organization_id)
      end

      def initialize(user, organization_id)
        @user = user
        @organization_id = organization_id
      end

      # ServiceResponse with id, token and username.
      def execute
        # Two page loads at once would otherwise both mint a token.
        in_lock("oc:unfurl_git_token:user:#{@user.id}", ttl: 30.seconds, retries: 20, sleep_sec: 0.1.seconds) do
          stored = UnfurlGitToken.find_by(user: @user) # rubocop:disable CodeReuse/ActiveRecord -- one indexed lookup
          next success(stored) if stored&.personal_access_token&.active?

          replace(stored)
        end
      rescue FailedToObtainLockError
        ServiceResponse.error(message: 'the token is being created; try again', reason: :service_unavailable)
      end

      private

      def replace(stored)
        response = ::PersonalAccessTokens::CreateService.new(
          current_user: @user,
          target_user: @user,
          organization_id: @organization_id,
          params: { name: ::OC::GIT_TOKEN_NAME, scopes: TOKEN_SCOPES, expires_at: TOKEN_LIFETIME.from_now.to_date.iso8601 }
        ).execute
        return response if response.error?

        created = response.payload[:personal_access_token]
        # The expiry mails are marked delivered so the notification workers
        # leave a token the user never asked for alone.
        created.update!(expire_notification_delivered: true, after_expiry_notification_delivered: true)

        row = stored || UnfurlGitToken.new(user: @user)
        replaced = stored&.personal_access_token

        ::ApplicationRecord.transaction do
          row.update!(personal_access_token: created, token: created.token)
          replaced&.destroy!
        end

        success(row)
      end

      def success(row)
        ServiceResponse.success(
          payload: { id: row.personal_access_token_id, token: row.token, username: @user.username })
      end
    end
  end
end
