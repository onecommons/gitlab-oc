# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OC::WorkItems::ItemEditsWorker, feature_category: :source_code_management do
  let_it_be(:project) { create(:project) }
  let_it_be(:user) { create(:user) }

  let(:args) { [project.id, user.id, 'a' * 40, 'b' * 40] }

  before do
    allow(project).to receive(:work_items_sync_enabled?).and_return(true)
    allow(Project).to receive(:find_by_id).with(project.id).and_return(project)
  end

  it 'applies the push as the pusher' do
    expect_next_instance_of(OC::WorkItems::ItemEditService, project, user) do |service|
      expect(service).to receive(:execute).with('a' * 40, 'b' * 40)
    end

    expect(described_class).not_to receive(:perform_in)

    described_class.new.perform(*args)
  end

  it 'does nothing while work items sync is off' do
    allow(project).to receive(:work_items_sync_enabled?).and_return(false)

    expect(OC::WorkItems::ItemEditService).not_to receive(:new)

    described_class.new.perform(*args)
  end

  it 'tries again later when another run holds the project' do
    worker = described_class.new
    allow(worker).to receive(:try_obtain_lease).and_return(nil)

    expect(described_class).to receive(:perform_in).with(described_class::RETRY_DELAY, *args)

    worker.perform(*args)
  end
end
