# frozen_string_literal: true

module OC
  module UserSettings
    module ProfilesController
      extend ActiveSupport::Concern
      extend ::Gitlab::Utils::Override

      private

      # The interface choice is offered as a choice, not as the `external` flag
      # it sets, which is what the sign-up form does too.
      override :user_params
      def user_params
        choice = params.require(:user).permit(:oc_interface)[:oc_interface]

        return super if choice.blank?

        super.merge(external: choice == 'deploy')
      end
    end
  end
end
