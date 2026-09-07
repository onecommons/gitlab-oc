# frozen_string_literal: true

module OC
  module AwardEmojis
    module AddService
      extend ::Gitlab::Utils::Override

      private

      override :after_create
      def after_create(award)
        super

        OC::WorkItems.enqueue_award_sync(awardable, current_user)
      end
    end
  end
end
