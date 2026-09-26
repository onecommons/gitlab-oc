# frozen_string_literal: true

require 'spec_helper'

# The override lives on OC::Topics::MergeService and is only reachable
# through the upstream class it is prepended onto.
RSpec.describe OC::Topics::MergeService, feature_category: :groups_and_projects do
  let_it_be(:organization) { create(:organization) }
  # Not let_it_be: the merge updates the target's counters and deletes the
  # source, which a frozen record refuses.
  let!(:source) { create(:topic, name: 'source', organization: organization) }
  let!(:target) { create(:topic, name: 'target', organization: organization) }
  let!(:only_source) { create(:project, topic_list: 'source', organization: organization) }
  let!(:both) { create(:project, topic_list: 'source, target', organization: organization) }
  let!(:only_target) { create(:project, topic_list: 'target', organization: organization) }

  def recorded
    OC::Projects::CloudmapEvent.metadata_changed
  end

  it 'records every project that carried the source topic' do
    expect(::Topics::MergeService.new(source, target).execute).to be_success

    expect(recorded.pluck(:project_id)).to match_array([only_source.id, both.id])
    expect(recorded.first.payload).to include('changed' => %w[topics], 'visibility' => 'private')
  end

  it 'records nothing when the merge is refused' do
    expect(::Topics::MergeService.new(nil, target).execute).to be_error

    expect(::Topics::MergeService.new(source, source).execute).to be_error

    expect(recorded).to be_empty
  end
end
