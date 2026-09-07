# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OC::WorkItems::SweepWorker, feature_category: :source_code_management do
  let(:worker) { described_class.new }

  def make_opted_in(project)
    project.custom_attributes.create!(key: 'unfurl_type', value: OC::REGULAR_PROJECT)
    project.custom_attributes.create!(key: 'work_items_sync', value: 'enabled')
  end

  describe '#perform' do
    # Unlike ReconcileWorker this asks for no window at all -- rebuilding
    # everything is the entire point, since what it exists to catch (a deleted
    # note, a toggled emoji) moved no timestamp a watermark could see.
    it 'enqueues an unfiltered full sync for every enabled project' do
      unfurl = create(:project).tap { |p| p.custom_attributes.create!(key: 'unfurl_type', value: OC::UNFURL_DASHBOARD) }
      opted_in = create(:project).tap { |p| make_opted_in(p) }

      expect(OC::WorkItems::FullSyncWorker).to receive(:perform_in).with(anything, unfurl.id)
      expect(OC::WorkItems::FullSyncWorker).to receive(:perform_in).with(anything, opted_in.id)

      worker.perform
    end

    # Deliberately not an updated_at check -- that would reintroduce the exact
    # blind spot this job exists to cover. Any activity at all is enough.
    it 'sweeps a project that has been touched since its last sweep' do
      project = create(:project).tap { |p| make_opted_in(p) }
      project.record_work_items_sync!(2.days.ago, unfiltered: true)
      project.update_column(:last_activity_at, 1.hour.ago)

      expect(OC::WorkItems::FullSyncWorker).to receive(:perform_in).with(anything, project.id)

      worker.perform
    end

    # The whole point on an instance with far more dormant projects than live
    # ones: a dead project was re-serializing records nobody had touched in a
    # year, every week, to commit nothing.
    it 'leaves a project alone when nothing has happened since its last sweep' do
      project = create(:project).tap { |p| make_opted_in(p) }
      project.update_column(:last_activity_at, 2.days.ago)
      project.record_work_items_sync!(1.day.ago, unfiltered: true)

      expect(OC::WorkItems::FullSyncWorker).not_to receive(:perform_in)

      worker.perform
    end

    it 'sweeps a project that has never been swept' do
      project = create(:project).tap { |p| make_opted_in(p) }
      project.update_column(:last_activity_at, 2.years.ago)

      expect(OC::WorkItems::FullSyncWorker).to receive(:perform_in).with(anything, project.id)

      worker.perform
    end

    # A scoped nightly pass is not a sweep, so it must not count as one.
    it 'still sweeps a project whose last pass was a scoped one' do
      project = create(:project).tap { |p| make_opted_in(p) }
      project.update_column(:last_activity_at, 1.hour.ago)
      project.record_work_items_sync!(Time.current, unfiltered: false)

      expect(project.work_items_swept_at).to be_nil
      expect(OC::WorkItems::FullSyncWorker).to receive(:perform_in).with(anything, project.id)

      worker.perform
    end

    it 'enqueues a project only once even when multiple attributes match' do
      project = create(:project)
      project.custom_attributes.create!(key: 'unfurl_type', value: OC::UNFURL_DASHBOARD)
      project.custom_attributes.create!(key: 'work_items_sync', value: 'enabled')

      expect(OC::WorkItems::FullSyncWorker).to receive(:perform_in).with(anything, project.id).once

      worker.perform
    end

    it 'skips projects that are not syncing' do
      create(:project).tap { |p| p.custom_attributes.create!(key: 'unfurl_type', value: OC::REGULAR_PROJECT) }

      expect(OC::WorkItems::FullSyncWorker).not_to receive(:perform_in)

      worker.perform
    end

    it 'staggers the enqueues so a large instance does not hit Gitaly at once' do
      first = create(:project).tap { |p| make_opted_in(p) }
      second = create(:project).tap { |p| make_opted_in(p) }

      expect(OC::WorkItems::FullSyncWorker).to receive(:perform_in).with(0, first.id).ordered
      expect(OC::WorkItems::FullSyncWorker).to receive(:perform_in)
        .with(described_class::ENQUEUE_INTERVAL, second.id).ordered

      worker.perform
    end
  end

  it 'runs at the lowest urgency, being background repair' do
    expect(described_class.get_urgency).to eq(:throttled)
  end
end
