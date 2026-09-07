# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OC::WorkItems::CommitNotesSyncWorker, feature_category: :source_code_management do
  let_it_be(:project) { create(:project) }

  let(:commit_id) { 'f0c7d1a94e3b6528d0b1f4a27c9e83b5d6a10f42' }
  let(:worker) { described_class.new }
  let(:sync_enabled) { true }
  let(:branch_exists) { true }
  let(:service) { instance_double(OC::WorkItems::SyncService, execute_commit_notes: 'sha') }

  before do
    allow(OC::WorkItems::SyncService).to receive(:new).and_return(service)

    allow_next_found_instance_of(Project) do |found|
      allow(found).to receive_messages(work_items_sync_enabled?: sync_enabled,
        repository: instance_double(Repository, branch_exists?: branch_exists))
    end
  end

  it_behaves_like 'an idempotent worker' do
    let(:job_args) { [project.id, 'f0c7d1a94e3b6528d0b1f4a27c9e83b5d6a10f42', nil] }
  end

  describe '#perform' do
    # There is no "record no longer exists" branch here as there is in
    # SyncWorker: the sha is still the file name after its last note is
    # deleted, so the worker always hands the sha to the service and the
    # service turns an empty note set into a file deletion.
    it 'syncs the file for the commit' do
      expect(service).to receive(:execute_commit_notes).with([commit_id])

      worker.perform(project.id, commit_id, nil)
    end

    it 'passes the acting user to the service' do
      user = create(:user)

      expect(OC::WorkItems::SyncService).to receive(:new)
        .with(kind_of(Project), triggered_by: user).and_return(service)

      worker.perform(project.id, commit_id, user.id)
    end

    context 'when the sync branch does not exist yet' do
      let(:branch_exists) { false }

      it 'defers to a full sync' do
        expect(OC::WorkItems::FullSyncWorker).to receive(:perform_async).with(project.id)
        expect(service).not_to receive(:execute_commit_notes)

        worker.perform(project.id, commit_id, nil)
      end
    end

    context 'when sync is disabled for the project' do
      let(:sync_enabled) { false }

      it 'does nothing' do
        expect(service).not_to receive(:execute_commit_notes)
        expect(OC::WorkItems::FullSyncWorker).not_to receive(:perform_async)

        worker.perform(project.id, commit_id, nil)
      end
    end

    it 'does nothing for an unknown project' do
      expect(service).not_to receive(:execute_commit_notes)

      worker.perform(non_existing_record_id, commit_id, nil)
    end

    it 'swallows pre-receive rejections instead of retrying' do
      allow(service).to receive(:execute_commit_notes)
        .and_raise(Gitlab::Git::PreReceiveError, 'GL-HOOK-ERR: denied')

      expect { worker.perform(project.id, commit_id, nil) }.not_to raise_error
    end
  end
end
