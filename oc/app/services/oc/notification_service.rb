# frozen_string_literal: true

module OC
  module NotificationService
    extend ::Gitlab::Utils::Override

    # The Unfurl git token is minted for the user by the integration rather than
    # requested by them, so a creation notice on every renewal is noise.
    override :access_token_created
    def access_token_created(user, token_name)
      super unless token_name == ::OC::GIT_TOKEN_NAME
    end
  end
end
