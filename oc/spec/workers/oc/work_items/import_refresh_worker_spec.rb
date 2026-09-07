# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OC::WorkItems::ImportRefreshWorker, feature_category: :source_code_management do
  let_it_be_with_reload(:project) { create(:project) }

  let(:worker) { described_class.new }
  let(:run) { instance_double(OC::WorkItems::ImportRunService, execute: nil) }

  before do
    allow(OC::WorkItems::ImportRunService).to receive(:new).and_return(run)
  end

  describe '#perform' do
    it 'does nothing for an unknown project' do
      expect(OC::WorkItems::ImportRunService).not_to receive(:new)

      worker.perform(non_existing_record_id)
    end

    it 'does nothing for a project that turned sync off' do
      project.enable_work_items_sync!(false)

      expect(OC::WorkItems::ImportRunService).not_to receive(:new)

      worker.perform(project.id)
    end

    # The nightly has no pusher, so it cannot check one. It is bounded instead:
    # only peers this project already holds replicas of. Otherwise it would be
    # a way around ImportWorker's owner check -- push as a developer, be
    # refused, and have the cron do it hours later.
    it 'touches only the peers already imported' do
      create(:oc_replicated_work_item, project: project, source_instance_uuid: 'peer-a')
      create(:oc_replicated_work_item, project: project, source_instance_uuid: 'peer-a',
        source_path: 'peer-a/issues/2.yml')
      create(:oc_replicated_work_item, project: project, source_instance_uuid: 'peer-b',
        source_path: 'peer-b/issues/1.yml')

      expect(run).to receive(:execute) do |directories:|
        expect(directories).to contain_exactly('peer-a', 'peer-b')
      end

      worker.perform(project.id)
    end

    it 'makes first contact with nobody' do
      expect(run).to receive(:execute).with(directories: [])

      worker.perform(project.id)
    end

    # Replicas belonging to someone else are not this project's peers, and the
    # bound would mean nothing if they were.
    it 'ignores peers another project mirrors' do
      create(:oc_replicated_work_item, project: create(:project), source_instance_uuid: 'peer-c')

      expect(run).to receive(:execute).with(directories: [])

      worker.perform(project.id)
    end

    # It takes a project id, not a directory list: the peers that matter are
    # the ones on record when the run happens, not when ReconcileWorker walked
    # the instance some minutes earlier.
    it 'reads the peer list when it runs' do
      create(:oc_replicated_work_item, project: project, source_instance_uuid: 'peer-a')

      expect(run).to receive(:execute).with(directories: ['peer-a'])

      worker.perform(project.id)
    end
  end
end
