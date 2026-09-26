# frozen_string_literal: true

module OC
  # OC Change -- records a namespace rename or transfer in the cloudmap feed.
  # Moving a namespace moves every project beneath it without writing any of
  # their rows. Caught on the model rather than in the services because a
  # username change reaches it only through User's autosave.
  module Namespace
    extend ActiveSupport::Concern

    prepended do
      # Noted on update and recorded on commit: Groups::TransferService
      # reloads the group inside its transaction, which clears
      # previous_changes before commit, and descendants' traversal_ids are
      # only settled once it commits.
      after_update :note_cloudmap_move, if: :saved_change_to_path_or_parent?, unless: :project_namespace?
      after_commit :record_cloudmap_move, if: -> { cloudmap_move.key?(:from) }
      after_rollback -> { cloudmap_move.clear }
    end

    private

    # An instance variable rather than an attribute, which reload would clear.
    def cloudmap_move
      @cloudmap_move ||= {}
    end

    # ||= so a second save in the same transaction keeps the original path.
    def note_cloudmap_move
      cloudmap_move[:from] ||= full_path_before_last_save
    end

    def record_cloudmap_move
      old_path = cloudmap_move.delete(:from)

      ::OC::Projects::CloudmapEvent.record_for_namespace_quietly(
        ::OC::Projects::CloudmapEvent.namespace_snapshot(self,
          namespace_type: type, old_path: old_path),
        kind: :namespace_moved)
    end
  end
end
