# frozen_string_literal: true

require 'spec_helper'

# The override lives on OC::Groups::DestroyService and is only reachable
# through the upstream class it is prepended onto.
RSpec.describe OC::Groups::DestroyService, feature_category: :groups_and_projects do
  let_it_be(:owner) { create(:user) }
  let!(:group) { create(:group, :public, owners: owner) }
  let!(:subgroup) { create(:group, parent: group) }
  let!(:project) { create(:project, namespace: subgroup) }

  subject(:destroy_group) { ::Groups::DestroyService.new(group, owner).execute }

  # Listed before the destroy: afterwards there is nothing left to list.
  it 'records the hierarchy the group held' do
    full_path = group.full_path

    destroy_group

    event = OC::Projects::CloudmapEvent.group_deleted.sole
    expect(event.project_path).to eq(full_path)
    expect(event.payload).to include(
      'namespace_id' => group.id, 'project_ids' => [project.id], 'subgroup_ids' => [subgroup.id])
  end

  # The destroy recurses into each subgroup through the method this overrides.
  it 'records the group once, beside each project\'s own tombstone' do
    destroy_group

    expect(OC::Projects::CloudmapEvent.group_deleted.count).to eq(1)
    expect(OC::Projects::CloudmapEvent.project_deleted.count).to eq(1)
  end

  it 'records a subgroup deleted on its own' do
    ::Groups::DestroyService.new(subgroup, owner).execute

    event = OC::Projects::CloudmapEvent.group_deleted.sole
    expect(event.payload).to include('namespace_id' => subgroup.id, 'project_ids' => [project.id])
  end

  # Users::DestroyService deletes solo-owned groups through unsafe_execute,
  # bypassing execute.
  it 'records a group deleted with the user who solely owned it', :enable_admin_mode do
    solo_owner = create(:user)
    solo_group = create(:group, owners: solo_owner)

    ::Users::DestroyService.new(create(:admin)).execute(solo_owner, delete_solo_owned_groups: true)

    expect(OC::Projects::CloudmapEvent.group_deleted.sole.payload).to include('namespace_id' => solo_group.id)
  end

  it 'records nothing when the destroy fails' do
    allow_next_instance_of(::Projects::DestroyService) do |service|
      allow(service).to receive(:execute).and_return(false)
    end

    expect { destroy_group }.to raise_error(::Groups::DestroyService::DestroyError)
    expect(OC::Projects::CloudmapEvent.group_deleted).to be_empty
  end

  it 'still succeeds when recording raises' do
    allow(OC::Projects::CloudmapEvent).to receive(:record_for_namespace).and_raise(ActiveRecord::StatementInvalid)

    expect(destroy_group).to be_success
    expect(::Group.find_by_id(group.id)).to be_nil
  end
end
