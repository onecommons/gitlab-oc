# frozen_string_literal: true

module OC
  module Issues
    module BaseService
      extend ::Gitlab::Utils::Override

      private

      # Fires for issue open/update/close/reopen (WorkItems services inherit
      # from Issues services, so work items are covered too).
      override :execute_hooks
      def execute_hooks(issue, action = 'open', old_associations: {})
        super
        OC::WorkItems.enqueue_sync(issue, current_user)
      end
    end
  end
end
