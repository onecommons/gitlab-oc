# frozen_string_literal: true

module OC
  module Projects
    module UpdateService
      extend ::Gitlab::Utils::Override

      # A project that syncs confidential issues and then becomes public (or
      # internal) has already published them: the files are deleted at the next
      # sync, but the content stays readable in the branch's history. Rebuild
      # the branch from scratch instead.
      #
      # The check before `super` is deliberately gated on private?: this service
      # runs for every project update on the instance, and a non-private project
      # cannot have been syncing confidential content anyway (see
      # Project#sync_confidential_work_items?), so the common case costs nothing.
      override :execute
      def execute
        was_syncing_confidential = project.private? && project.sync_confidential_work_items?

        super.tap do |result|
          # On the validation-error path the captured value is simply unused.
          next unless result.is_a?(Hash) && result[:status] == :success

          OC::WorkItems.purge_confidential_history(project, was_syncing_confidential)
        end
      end
    end
  end
end
