# frozen_string_literal: true

module OC
  module Environments
    # Google sign-in for an environment's provider.
    #
    # Only the two grants the consent screen asks for: list the account's
    # projects, and create the service account the first deployment makes.
    # Upstream's SCOPE is far wider and is shared with Cloud Seed, so it is
    # subclassed rather than edited.
    class GoogleCloudClient < ::GoogleApi::CloudPlatform::Client
      SCOPE = 'https://www.googleapis.com/auth/cloudplatformprojects https://www.googleapis.com/auth/iam'

      def scope
        SCOPE
      end
    end
  end
end
