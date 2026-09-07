# frozen_string_literal: true

module OC
  module EverySidekiqWorkerTestHelper
    extend ::Gitlab::Utils::Override

    override :extra_retry_exceptions
    def extra_retry_exceptions
      super.merge(
        'OC::WorkItems::CommitNotesSyncWorker' => 3,
        'OC::WorkItems::FullSyncWorker' => 3,
        'OC::WorkItems::ImportRefreshWorker' => 3,
        'OC::WorkItems::ImportWorker' => 3,
        'OC::WorkItems::SyncWorker' => 3
      )
    end
  end
end
