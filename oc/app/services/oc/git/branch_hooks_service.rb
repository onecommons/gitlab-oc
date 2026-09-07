# frozen_string_literal: true

module OC
  module Git
    module BranchHooksService
      extend ::Gitlab::Utils::Override

      # A push to the sync branch may be carrying another instance's work
      # items, so it is what starts an import.
      #
      # Our own sync commits arrive here too -- commit_files runs the
      # post-receive path like any other push -- and that is harmless: the run
      # only looks at directories that are not ours, and reconciling against an
      # unchanged branch does nothing.
      #
      # Whether the pusher may actually import is decided in the worker, not
      # here. Refusing at this point would mean failing the push, and the push
      # itself is fine: the branch is data, importing it is a privileged
      # reading of that data.
      #
      # That includes a push with no identified pusher, which the worker treats
      # as unauthorized like any other. Enqueueing it anyway, rather than
      # skipping it here, is what gets the skip into the log.
      override :execute
      def execute
        result = super

        enqueue_work_items_import

        result
      end

      private

      # Nothing to import from a branch that has just been deleted -- and the
      # deletion is not a signal to delete replicas either. That decision
      # belongs to a run that can see the tree, not to the absence of one.
      def enqueue_work_items_import
        return unless work_items_sync_ref?
        return if ::Gitlab::Git.blank_ref?(newrev)

        OC::WorkItems::ImportWorker.perform_async(project.id, current_user&.id)
      end

      # The work items sync branch is machine-managed: its commit messages are
      # generated, not written by anyone, and must never be read as referring
      # to anything.
      #
      # Upstream runs this on every branch, not just the default one. A
      # reference token (`#N`, `!N`, `%N`, ...) anywhere in a sync commit
      # message would stamp a "mentioned in commit" system note on the
      # referenced record -- which is a change to that record, which triggers
      # another sync, which writes the same message again. Part of the message
      # is deploy-supplied (the version trailer), so the branch opts out
      # entirely rather than depending on what that value happens to contain.
      #
      # `work_items_sync_ref?` comes from OC::Git::BaseHooksService, prepended
      # to this class's superclass. This has to be its own module because
      # enqueue_process_commit_messages is defined on BranchHooksService
      # itself: a module prepended to the parent sits behind the child's own
      # methods in the ancestor chain and would never be reached.
      override :enqueue_process_commit_messages
      def enqueue_process_commit_messages
        return if work_items_sync_ref?

        super
      end
    end
  end
end
