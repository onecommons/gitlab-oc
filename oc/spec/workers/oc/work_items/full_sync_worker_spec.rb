# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OC::WorkItems::FullSyncWorker, feature_category: :source_code_management do
  let_it_be(:project) { create(:project) }
  let_it_be_with_reload(:issues) { create_list(:issue, 3, project: project) }

  let(:worker) { described_class.new }
  let(:sync_enabled) { true }
  let(:service) do
    instance_double(OC::WorkItems::SyncService,
      execute: 'sha', execute_catalogs: nil, remove_orphans: nil)
  end

  before do
    allow(OC::WorkItems::SyncService).to receive(:new).and_return(service)

    allow_next_found_instance_of(Project) do |found|
      allow(found).to receive(:work_items_sync_enabled?).and_return(sync_enabled)
    end
  end

  it_behaves_like 'an idempotent worker' do
    let(:job_args) { [project.id] }
  end

  describe '#perform' do
    it 'syncs all issues in batches' do
      synced_ids = []
      allow(service).to receive(:execute) { |batch| synced_ids.concat(batch.map(&:id)) }

      worker.perform(project.id)

      expect(synced_ids).to match_array(issues.map(&:id))
    end

    # Label and milestone edits fire no issuable hook, so this is the only
    # thing that ever writes the catalogs.
    it 'writes the label and milestone catalogs' do
      expect(service).to receive(:execute_catalogs)

      worker.perform(project.id)
    end

    context 'with a window' do
      let(:recent) { create(:issue, project: project, updated_at: 1.hour.ago) }
      let(:since) { 12.hours.ago.utc.iso8601 }

      before do
        recent
        issues.each { |issue| issue.update_column(:updated_at, 2.days.ago) }
        allow_next_found_instance_of(Project) do |found|
          allow(found).to receive_messages(work_items_sync_enabled?: sync_enabled,
            repository: instance_double(Repository, branch_exists?: true))
        end
      end

      it 'serializes only the records that changed inside it' do
        synced_ids = []
        allow(service).to receive(:execute) { |batch| synced_ids.concat(batch.map(&:id)) }

        worker.perform(project.id, false, since)

        expect(synced_ids).to contain_exactly(recent.id)
      end

      # Their embedded copies are what a label rename changes, and the reconcile
      # forces an unfiltered pass whenever one moved -- so a scoped pass has no
      # reason to rewrite them.
      it 'leaves the catalogs alone' do
        expect(service).not_to receive(:execute_catalogs)

        worker.perform(project.id, false, since)
      end

      # A deleted record moves no timestamp, so this is its only backstop.
      it 'still collects orphans' do
        expect(service).to receive(:remove_orphans)

        worker.perform(project.id, false, since)
      end

      # Including a branch someone deleted by hand: there is nothing to be
      # incremental against, so the window is meaningless.
      it 'ignores the window when the branch does not exist' do
        allow_next_found_instance_of(Project) do |found|
          allow(found).to receive_messages(work_items_sync_enabled?: true,
            repository: instance_double(Repository, branch_exists?: false))
        end
        synced_ids = []
        allow(service).to receive(:execute) { |batch| synced_ids.concat(batch.map(&:id)) }

        worker.perform(project.id, false, since)

        expect(synced_ids).to match_array(issues.map(&:id) + [recent.id])
        expect(service).to have_received(:execute_catalogs)
      end
    end

    # Captured before anything is read, so a record changed mid-pass falls
    # after the watermark and is caught next time instead of being skipped.
    it 'stamps its commits with the moment it started scanning' do
      started = nil
      allow(OC::WorkItems::SyncService).to receive(:new) do |_project, **kwargs|
        started = kwargs[:synced_through]
        service
      end

      worker.perform(project.id)

      expect(started).to be_within(1.minute).of(Time.current)
    end

    # What lets both cron jobs dismiss a project without reading its branch.
    describe 'the marker it leaves behind' do
      it 'records when it scanned, and that the scan was unfiltered' do
        worker.perform(project.id)

        expect(project.reload.work_items_synced_at).to be_within(1.minute).of(Time.current)
        expect(project.work_items_swept_at).to be_within(1.minute).of(Time.current)
      end

      # A scoped pass looked at part of the project, so it cannot stand in for
      # the weekly sweep -- which exists precisely to look at everything.
      it 'records no sweep for a scoped pass' do
        allow_next_found_instance_of(Project) do |found|
          allow(found).to receive_messages(work_items_sync_enabled?: true,
            repository: instance_double(Repository, branch_exists?: true))
        end

        worker.perform(project.id, false, 1.day.ago.utc.iso8601)

        expect(project.reload.work_items_synced_at).to be_present
        expect(project.work_items_swept_at).to be_nil
      end

      it 'records nothing when the pass was rejected' do
        allow(service).to receive(:execute).and_raise(Gitlab::Git::PreReceiveError, 'GL-HOOK-ERR: denied')

        worker.perform(project.id)

        expect(project.reload.work_items_synced_at).to be_nil
      end

      context 'when sync is disabled' do
        let(:sync_enabled) { false }

        it 'records nothing, so enabling it later still triggers a pass' do
          worker.perform(project.id)

          expect(project.reload.work_items_synced_at).to be_nil
        end
      end
    end

    it 'garbage collects orphaned files after the batch pass' do
      expect(service).to receive(:remove_orphans)

      worker.perform(project.id)
    end

    context 'when sync is disabled' do
      let(:sync_enabled) { false }

      it 'does nothing' do
        expect(service).not_to receive(:execute)
        expect(service).not_to receive(:execute_catalogs)

        worker.perform(project.id)
      end
    end

    it 'swallows pre-receive rejections instead of retrying' do
      allow(service).to receive(:execute).and_raise(Gitlab::Git::PreReceiveError, 'GL-HOOK-ERR: denied')

      expect { worker.perform(project.id) }.not_to raise_error
    end

    context 'with purge_history' do
      let(:service) do
        instance_double(OC::WorkItems::SyncService,
          execute: 'sha', execute_catalogs: nil, remove_orphans: nil, purge_own_history!: true)
      end

      it 'replaces the branch before rebuilding it' do
        expect(service).to receive(:purge_own_history!).ordered
        expect(service).to receive(:execute).at_least(:once).ordered

        worker.perform(project.id, true)
      end

      # Not delete_branch!, which takes each peer's directory with it. Those
      # cannot be rebuilt from local records, and losing them makes the next
      # import run delete every replica in the project.
      it 'never deletes the branch outright' do
        expect(service).not_to receive(:delete_branch!)

        worker.perform(project.id, true)
      end

      it 'does not purge by default' do
        expect(service).not_to receive(:purge_own_history!)

        worker.perform(project.id)
      end

      context 'when sync is disabled' do
        let(:sync_enabled) { false }

        # The worst case to get wrong: this path returns before any rebuild,
        # so anything the purge dropped would have nothing to put it back.
        it 'still purges, because the disabled project keeps its branch' do
          expect(service).to receive(:purge_own_history!)
          expect(service).not_to receive(:execute)

          worker.perform(project.id, true)
        end
      end
    end
  end
end
