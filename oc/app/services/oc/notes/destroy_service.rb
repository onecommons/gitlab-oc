# frozen_string_literal: true

module OC
  module Notes
    module DestroyService
      extend ::Gitlab::Utils::Override

      override :execute
      def execute(note, **)
        # Load (and memoize) the noteable while the row is still intact, so
        # the enqueue after `super` does not have to go back to the database.
        # Commit notes are exempt: their noteable is a Gitaly lookup, and
        # OC::WorkItems.enqueue_note_sync reads only their columns.
        note.noteable unless note.for_commit?

        result = super

        OC::WorkItems.enqueue_note_sync(note, current_user)

        result
      end
    end
  end
end
