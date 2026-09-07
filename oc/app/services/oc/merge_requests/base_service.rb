# frozen_string_literal: true

module OC
  module MergeRequests
    module BaseService
      extend ::Gitlab::Utils::Override

      # Fires for MR open/update/close/reopen/merge.
      override :execute_hooks
      def execute_hooks(merge_request, action = 'open', **)
        super
        OC::WorkItems.enqueue_sync(merge_request, current_user)
      end
    end
  end
end
