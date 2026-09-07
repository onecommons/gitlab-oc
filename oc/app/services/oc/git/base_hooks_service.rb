# frozen_string_literal: true

module OC
  module Git
    module BaseHooksService
      extend ::Gitlab::Utils::Override

      private

      # The work items sync branch is machine-managed: never run pipelines
      # for it. Gitaly's UserCommitFiles RPC cannot carry `ci.skip` push
      # options, so this is the equivalent of `git push -o ci.skip`, enforced
      # where the pipeline would be created -- and unlike the push option, no
      # skipped pipeline row is left behind.
      override :create_pipeline
      def create_pipeline
        return if work_items_sync_ref?

        super
      end

      # Exact match on the full ref so a tag of the same name is unaffected.
      def work_items_sync_ref?
        ref == "refs/heads/#{OC::WorkItems::SYNC_BRANCH}"
      end
    end
  end
end
