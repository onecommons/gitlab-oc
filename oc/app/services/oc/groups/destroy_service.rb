# frozen_string_literal: true

module OC
  module Groups
    # OC Change -- Groups::GroupDeletedEvent is published after the projects
    # and subgroups are destroyed, so a subscriber could not list them. They
    # are read here, before the destroy.
    #
    # On unsafe_execute rather than execute, because Users::DestroyService
    # deletes a user's solo-owned groups through it directly.
    module DestroyService
      extend ::Gitlab::Utils::Override

      override :unsafe_execute
      def unsafe_execute
        # unsafe_execute recurses into each subgroup; one row covers the
        # hierarchy. The parent's state is persisted by the outer call's
        # mark_deletion_in_progress before it recurses.
        return super if group.parent&.deletion_in_progress?

        snapshot = ::OC::Projects::CloudmapEvent.namespace_snapshot(group)

        result = super
        ::OC::Projects::CloudmapEvent.record_for_namespace_quietly(snapshot, kind: :group_deleted)

        result
      end
    end
  end
end
