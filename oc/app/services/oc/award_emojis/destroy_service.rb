# frozen_string_literal: true

module OC
  module AwardEmojis
    module DestroyService
      extend ::Gitlab::Utils::Override

      private

      override :after_destroy
      def after_destroy(award)
        super

        OC::WorkItems.enqueue_award_sync(awardable, current_user)
      end
    end
  end
end
