# frozen_string_literal: true

module OC
  module NotificationService
    extend ::Gitlab::Utils::Override

    # Unfurl's git tokens are minted and renewed by the integration rather than
    # requested by anyone, so a notice on every renewal is noise.
    UNFURL_TOKEN_NAMES = [::OC::GIT_TOKEN_NAME, ::OC::CLOUDMAP_PUSH_TOKEN_NAME].freeze

    override :access_token_created
    def access_token_created(user, token_name)
      super unless UNFURL_TOKEN_NAMES.include?(token_name)
    end

    override :access_token_rotated
    def access_token_rotated(user, token_name)
      super unless UNFURL_TOKEN_NAMES.include?(token_name)
    end
  end
end
