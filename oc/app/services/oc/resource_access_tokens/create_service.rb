# frozen_string_literal: true

module OC
  module ResourceAccessTokens
    module CreateService
      extend ::Gitlab::Utils::Override

      private

      # The model permits the empty expiry; this lets the request carrying no
      # `expires_at` reach it, rather than being refused as a bad request first.
      override :validate_expires_at_field
      def validate_expires_at_field(params)
        return true if params[:name] == ::OC::PROJECT_TOKEN_NAME

        super
      end
    end
  end
end
