# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OC::WorkItems::DraftsWorker, feature_category: :source_code_management do
  let_it_be(:project) { create(:project) }
  let_it_be(:user) { create(:user) }
  let(:result) { OC::WorkItems::DraftService::Result.new(created: [], skipped: {}, stale: [], more: false) }

  before do
    allow(project).to receive(:work_items_sync_enabled?).and_return(true)
    allow(Project).to receive(:find_by_id).with(project.id).and_return(project)
  end

  it 'runs the drafts as the pusher, and does not queue itself again when it is done' do
    expect_next_instance_of(OC::WorkItems::DraftService, project, user) do |service|
      expect(service).to receive(:execute).and_return(result)
    end

    expect(described_class).not_to receive(:perform_in)
    expect(described_class).not_to receive(:perform_async)

    described_class.new.perform(project.id, user.id)
  end

  it 'removes drafts whose key was already used' do
    result.stale = ['uuid/_incoming/old.yml']
    allow_next_instance_of(OC::WorkItems::DraftService) { |service| allow(service).to receive(:execute).and_return(result) }

    expect_next_instance_of(OC::WorkItems::SyncService, project, triggered_by: user) do |sync|
      expect(sync).to receive(:remove_drafts).with(['uuid/_incoming/old.yml'])
    end

    described_class.new.perform(project.id, user.id)
  end

  it 'leaves drafts alone while work items sync is off' do
    allow(project).to receive(:work_items_sync_enabled?).and_return(false)

    expect(OC::WorkItems::DraftService).not_to receive(:new)

    described_class.new.perform(project.id, user.id)
  end

  it 'queues itself again while drafts remain' do
    result.more = true
    allow_next_instance_of(OC::WorkItems::DraftService) { |service| allow(service).to receive(:execute).and_return(result) }

    expect(described_class).to receive(:perform_async).with(project.id, user.id)

    described_class.new.perform(project.id, user.id)
  end

  it 'tries again later when another run holds the project' do
    worker = described_class.new
    allow(worker).to receive(:try_obtain_lease).and_return(nil)

    expect(described_class).to receive(:perform_in).with(described_class::RETRY_DELAY, project.id, user.id)

    worker.perform(project.id, user.id)
  end
end
