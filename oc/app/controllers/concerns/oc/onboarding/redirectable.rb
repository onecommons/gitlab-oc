# frozen_string_literal: true

module OC
  module Onboarding
    module Redirectable
      extend ActiveSupport::Concern
      extend ::Gitlab::Utils::Override

      private

      # A new user's own dashboard is the landing page. This covers the form
      # and OmniAuth signups in one place; an invitation still wins, because
      # someone who followed one meant to go there.
      override :after_sign_up_path
      def after_sign_up_path
        return super if onboarding_status_presenter.single_invite?

        unfurl_home_index_path
      end
    end
  end
end
