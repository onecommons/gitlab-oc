# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OC::GroupCustomAttribute, feature_category: :groups_and_projects do
  let_it_be(:group) { create(:group, :public) }
  let_it_be(:subgroup) { create(:group, :public, parent: group) }
  let_it_be(:nested_project) { create(:project, :public, namespace: subgroup) }

  let(:key) { described_class::CLOUDMAP_INCLUDE_ALL_PUBLIC }

  def included_rows
    OC::Projects::CloudmapEvent.group_included
  end

  def mark(value = 'true')
    group.custom_attributes.find_or_initialize_by(key: key).update!(value: value)
  end

  it 'records the hierarchy when the mark is set' do
    mark

    expect(included_rows.sole.payload).to include(
      'namespace_id' => group.id, 'project_ids' => [nested_project.id], 'subgroup_ids' => [subgroup.id])
  end

  it 'records it again when the mark is turned back on' do
    mark
    mark('false')
    mark

    expect(included_rows.count).to eq(2)
  end

  it 'records nothing for a mark set to anything but true' do
    mark('false')

    expect(included_rows).to be_empty
  end

  it 'records nothing when the mark is saved unchanged' do
    mark
    group.custom_attributes.find_by(key: key).touch

    expect(included_rows.count).to eq(1)
  end

  it 'records nothing for another key' do
    group.custom_attributes.create!(key: 'something_else', value: 'true')

    expect(included_rows).to be_empty
  end

  it 'lists the groups that are marked' do
    mark
    create(:group).custom_attributes.create!(key: key, value: 'false')

    expect(GroupCustomAttribute.cloudmap_including_group_ids).to eq([group.id])
  end
end
