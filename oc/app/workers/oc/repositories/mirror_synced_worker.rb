# frozen_string_literal: true

module OC
  module Repositories
    # OC Change -- does for a pull mirror what post-receive does for a push.
    # fetch_as_mirror runs no hook, so without this a mirrored change to an
    # Unfurl file stays stale in the Unfurl server's cache, and a mirror that
    # gains or loses one is never reclassified.
    class MirrorSyncedWorker
      include ::Gitlab::EventStore::Subscriber

      feature_category :source_code_management
      urgency :high
      data_consistency :always
      # Only enqueues; both workers it starts are idempotent.
      idempotent!

      # The repository method caches classification reads. A fetch expires
      # none of them.
      CLASSIFICATION_FILES = %w[ensemble_template_yaml unfurl_yaml].freeze

      def handle_event(event)
        project_id = event.data[:project_id]

        ::OC::Repositories::ProjectUnfurlCacheWorker.perform_async(
          project_id,
          "#{::Gitlab::Git::BRANCH_REF_PREFIX}#{event.data[:ref]}",
          event.data[:old_sha] || ::Gitlab::Git::SHA1_BLANK_SHA,
          event.data[:new_sha])

        ::ProjectCacheWorker.perform_async(project_id, CLASSIFICATION_FILES, [], false)
      end
    end
  end
end
