# frozen_string_literal: true

module OC
  module Notes
    module PostProcessService
      extend ::Gitlab::Utils::Override

      # Fires post-commit for created notes (via NewNoteWorker).
      override :execute
      def execute
        super

        OC::WorkItems.enqueue_note_sync(note, note.author)
      end
    end
  end
end
