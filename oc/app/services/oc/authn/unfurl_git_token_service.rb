# frozen_string_literal: true

module OC
  module Authn
    # OC Change -- the git token handed to the Unfurl server, kept encrypted in
    # OC::Authn::UnfurlGitToken and reused while it is active.
    #
    # Two owners:
    # - a user (.for_user), whose token lets a deployment push its results
    #   back. An inactive one is replaced and deleted, since nothing cleans up
    #   people's expired tokens.
    # - the cloudmap's project bot (.for_project_bot), so the cloudmap
    #   worker's commits can be pushed with a credential of their own. Rotated
    #   a day before it expires, so a push in flight never holds a token that
    #   runs out during its retries.
    class UnfurlGitTokenService
      include ::Gitlab::ExclusiveLeaseHelpers

      TOKEN_SCOPES = %w[read_repository write_repository].freeze
      TOKEN_LIFETIME = 7.days

      BOT_SCOPES = %w[write_repository].freeze
      # The cloudmap's default branch admits pushes from Maintainers only.
      BOT_ACCESS_LEVEL = ::Gitlab::Access::MAINTAINER
      BOT_REFRESH_WINDOW = 1.day

      def self.for_user(user, organization_id:)
        new(user: user, organization_id: organization_id)
      end

      def self.for_project_bot(project)
        new(project: project, organization_id: project.organization_id)
      end

      def initialize(organization_id:, user: nil, project: nil)
        @user = user
        @project = project
        @organization_id = organization_id
      end

      # ServiceResponse with id, token and username.
      def execute
        # Two requests at once would otherwise both mint a token.
        # Up to 5 seconds' wait: minting can take a while on a cold instance.
        in_lock(lock_key, ttl: 30.seconds, retries: 50, sleep_sec: 0.1.seconds) do
          @project ? execute_for_bot : execute_for_user
        end
      rescue FailedToObtainLockError
        ServiceResponse.error(message: 'the token is being created; try again', reason: :service_unavailable)
      end

      private

      def lock_key
        @project ? "oc:unfurl_git_token:project_bot:#{@project.id}" : "oc:unfurl_git_token:user:#{@user.id}"
      end

      def execute_for_user
        stored = UnfurlGitToken.find_by(user: @user) # rubocop:disable CodeReuse/ActiveRecord -- one indexed lookup
        return success(stored) if stored&.personal_access_token&.active?

        response = ::PersonalAccessTokens::CreateService.new(
          current_user: @user,
          target_user: @user,
          organization_id: @organization_id,
          params: { name: ::OC::GIT_TOKEN_NAME, scopes: TOKEN_SCOPES, expires_at: TOKEN_LIFETIME.from_now.to_date.iso8601 }
        ).execute
        return response if response.error?

        store(stored, response.payload[:personal_access_token], dispose: :destroy)
      end

      # Only rows this service wrote are ever bots', so another bot on the
      # project (the frontend's UNFURL_PROJECT_TOKEN one) is never picked up.
      # rubocop:disable CodeReuse/ActiveRecord -- two indexed lookups
      def execute_for_bot
        stored = UnfurlGitToken.find_by(user_id: @project.bots.pluck(:id))
        token = stored&.personal_access_token
        return success(stored) if token&.active? && !refresh_due?(token)

        as_admin_bot do
          rotated = rotate(token) if token && !token.revoked?
          next store(stored, rotated) if rotated

          create_bot_token(stored)
        end
      end
      # rubocop:enable CodeReuse/ActiveRecord

      # A token with no expiry needs no refresh.
      def refresh_due?(token)
        token.expires_at.present? && token.expires_at <= BOT_REFRESH_WINDOW.from_now.to_date
      end

      # Same bot, a new token; the old one is revoked by the rotation and kept
      # for the audit trail. nil when the rotation is refused (for example a
      # legacy token while granular tokens are enforced): a new bot then.
      def rotate(token)
        response = ::ProjectAccessTokens::RotateService.new(
          @admin_bot, token, @project, expires_at: TOKEN_LIFETIME.from_now.to_date
        ).execute
        response.payload[:personal_access_token] if response.success?
      end

      # A replaced bot is left to InactiveTokensDeletionCronWorker.
      def create_bot_token(stored)
        response = ::ResourceAccessTokens::CreateService.new(
          @admin_bot, @project,
          name: ::OC::CLOUDMAP_PUSH_TOKEN_NAME, scopes: BOT_SCOPES, access_level: BOT_ACCESS_LEVEL,
          expires_at: TOKEN_LIFETIME.from_now.to_date
        ).execute
        return response if response.error?

        store(stored, response.payload[:access_token], replace_owner: true)
      end

      # A cron job has no person to act as. The admin bot, with admin mode
      # bypassed, as other workers that manage tokens do.
      def as_admin_bot(&block)
        @admin_bot = ::Users::Internal.in_organization(@organization_id).admin_bot
        ::Gitlab::Auth::CurrentUserMode.bypass_session!(@admin_bot.id, &block)
      end

      # dispose: :destroy deletes the token this one replaces; a rotation has
      # already revoked it, and a replaced bot's goes with the bot.
      def store(stored, created, dispose: nil, replace_owner: false)
        # The expiry mails are marked delivered so the notification workers do
        # not write to anyone about a token nobody asked for.
        created.update!(expire_notification_delivered: true, after_expiry_notification_delivered: true)

        replaced = stored&.personal_access_token
        row = stored && !replace_owner ? stored : UnfurlGitToken.new(user: created.user)

        ::ApplicationRecord.transaction do
          stored.destroy! if stored && replace_owner
          row.update!(personal_access_token: created, token: created.token)
          replaced.destroy! if replaced && dispose == :destroy
        end

        success(row)
      end

      def success(row)
        ServiceResponse.success(
          payload: { id: row.personal_access_token_id, token: row.token, username: row.user.username })
      end
    end
  end
end
