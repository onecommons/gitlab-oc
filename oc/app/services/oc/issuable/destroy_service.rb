# frozen_string_literal: true

module OC
  module Issuable
    module DestroyService
      extend ::Gitlab::Utils::Override

      # Removes the synced file when an issue/MR is deleted. The record is
      # already destroyed; enqueue_sync only reads in-memory attributes and
      # the worker's remove path deletes by iid.
      override :execute
      def execute(issuable)
        result = super

        OC::WorkItems.enqueue_sync(issuable, current_user) if issuable.destroyed? && OC::WorkItems.syncable?(issuable)

        result
      end
    end
  end
end
