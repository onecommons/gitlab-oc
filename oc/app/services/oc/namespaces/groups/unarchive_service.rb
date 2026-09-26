# frozen_string_literal: true

module OC
  module Namespaces
    module Groups
      # OC Change -- upstream publishes the same GroupArchivedEvent for both
      # directions, carrying only ids, so a subscriber cannot tell which
      # happened. Recorded here, where it is known.
      module UnarchiveService
        extend ::Gitlab::Utils::Override

        private

        override :publish_events
        def publish_events
          super

          ::OC::Projects::CloudmapEvent.record_for_namespace_quietly(
            ::OC::Projects::CloudmapEvent.namespace_snapshot(group), kind: :group_unarchived)
        end
      end
    end
  end
end
