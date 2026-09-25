# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OC::Projects::PruneCloudmapEventsWorker, feature_category: :source_code_management do
  let_it_be(:project) { create(:project) }

  let(:retention) { described_class::RETENTION }

  def event_at(time)
    create(:oc_cloudmap_event, project: project, occurred_at: time)
  end

  it 'deletes rows older than the retention and keeps the rest' do
    old = event_at(retention.ago - 1.day)
    fresh = event_at(1.hour.ago)

    described_class.new.perform

    expect(OC::Projects::CloudmapEvent.all).to contain_exactly(fresh)
    expect { old.reload }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it 'keeps a row exactly at the boundary' do
    boundary = event_at(retention.ago + 1.minute)

    described_class.new.perform

    expect(OC::Projects::CloudmapEvent.all).to contain_exactly(boundary)
  end

  # Capped rather than looped, so a run that finds more leaves the rest for the
  # next one. Stubbed low because the real cap is 10,000.
  it 'deletes no more than DELETE_LIMIT rows in one run' do
    stub_const("#{described_class}::DELETE_LIMIT", 1)
    2.times { event_at(retention.ago - 1.day) }

    expect { described_class.new.perform }
      .to change { OC::Projects::CloudmapEvent.count }.from(2).to(1)
  end
end
