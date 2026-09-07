# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OC::WorkItems::SyncWorker, feature_category: :source_code_management do
  let_it_be(:project) { create(:project) }
  let_it_be(:issue) { create(:issue, project: project) }

  let(:worker) { described_class.new }
  let(:sync_enabled) { true }
  let(:branch_exists) { true }
  let(:service) { instance_double(OC::WorkItems::SyncService, execute: 'sha', remove: nil) }

  before do
    allow(OC::WorkItems::SyncService).to receive(:new).and_return(service)

    allow_next_found_instance_of(Project) do |found|
      allow(found).to receive_messages(work_items_sync_enabled?: sync_enabled,
        repository: instance_double(Repository, branch_exists?: branch_exists))
    end
  end

  it_behaves_like 'an idempotent worker' do
    let(:job_args) { [project.id, 'Issue', issue.id, issue.iid, nil] }
  end

  describe '#perform' do
    it 'syncs the issuable' do
      expect(service).to receive(:execute) do |issuables|
        expect(issuables.map(&:id)).to eq([issue.id])
      end

      worker.perform(project.id, 'Issue', issue.id, issue.iid, nil)
    end

    it 'passes the acting user to the service' do
      user = create(:user)

      expect(OC::WorkItems::SyncService).to receive(:new)
        .with(kind_of(Project), triggered_by: user).and_return(service)

      worker.perform(project.id, 'Issue', issue.id, issue.iid, user.id)
    end

    it 'removes the file when the issuable no longer exists' do
      expect(service).to receive(:remove).with('Issue', 424_242)
      expect(service).not_to receive(:execute)

      worker.perform(project.id, 'Issue', non_existing_record_id, 424_242, nil)
    end

    context 'when the sync branch does not exist yet' do
      let(:branch_exists) { false }

      it 'defers to a full sync' do
        expect(OC::WorkItems::FullSyncWorker).to receive(:perform_async).with(project.id)
        expect(service).not_to receive(:execute)

        worker.perform(project.id, 'Issue', issue.id, issue.iid, nil)
      end
    end

    context 'when sync is disabled for the project' do
      let(:sync_enabled) { false }

      it 'does nothing' do
        expect(service).not_to receive(:execute)
        expect(OC::WorkItems::FullSyncWorker).not_to receive(:perform_async)

        worker.perform(project.id, 'Issue', issue.id, issue.iid, nil)
      end
    end

    it 'does nothing for an unknown project' do
      expect(service).not_to receive(:execute)

      worker.perform(non_existing_record_id, 'Issue', issue.id, issue.iid, nil)
    end

    it 'swallows pre-receive rejections instead of retrying' do
      allow(service).to receive(:execute).and_raise(Gitlab::Git::PreReceiveError, 'GL-HOOK-ERR: denied')

      expect { worker.perform(project.id, 'Issue', issue.id, issue.iid, nil) }.not_to raise_error
    end
  end
end
