# frozen_string_literal: true

module OC
  module Gitlab
    module EventStore
      extend ActiveSupport::Concern

      OC_SUBSCRIPTION_GROUPS = [
        ::Gitlab::EventStore::Subscriptions::OCSubscriptions
      ].freeze

      class_methods do
        extend ::Gitlab::Utils::Override

        override :subscription_groups
        def subscription_groups
          super + OC_SUBSCRIPTION_GROUPS
        end
      end
    end
  end
end
