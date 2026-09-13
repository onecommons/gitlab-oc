# frozen_string_literal: true

module OC
  module Import
    module GithubController
      extend ActiveSupport::Concern
      extend ::Gitlab::Utils::Override

      private

      # OC Change -- mirroring by default
      # Import params are allowlisted, so the browser cannot opt out of
      # mirroring unless this is declared.
      override :permitted_import_params
      def permitted_import_params
        super + [:enable_mirroring]
      end
    end
  end
end
