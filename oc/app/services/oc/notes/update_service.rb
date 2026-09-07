# frozen_string_literal: true

module OC
  module Notes
    module UpdateService
      extend ::Gitlab::Utils::Override

      # Note edits do not go through PostProcessService.
      override :execute
      def execute(note)
        result = super

        OC::WorkItems.enqueue_note_sync(note, current_user)

        result
      end
    end
  end
end
