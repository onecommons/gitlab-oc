# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OC::Namespace, feature_category: :groups_and_projects do
  let_it_be(:owner) { create(:user) }

  def moves
    OC::Projects::CloudmapEvent.namespace_moved
  end

  describe 'a username change' do
    let!(:user) { create(:user, :with_namespace, username: 'before') }
    let!(:project) { create(:project, namespace: user.namespace) }

    # Reaches the namespace only through User's autosave.
    it 'records the user namespace with its projects' do
      ::Users::UpdateService.new(user, user: user, username: 'after').execute

      event = moves.sole
      expect(event.project_path).to eq('after')
      expect(event.payload).to include(
        'namespace_type' => 'User', 'old_path' => 'before',
        'namespace_id' => user.namespace.id, 'project_ids' => [project.id])
      expect(event.payload).not_to have_key('subgroup_ids')
    end
  end

  describe 'a group move' do
    let!(:group) { create(:group, :public, path: 'source', owners: owner) }
    let!(:subgroup) { create(:group, parent: group, path: 'child') }
    let!(:nested_project) { create(:project, namespace: subgroup) }
    let!(:target) { create(:group, path: 'target', owners: owner) }

    it 'records a rename with the hierarchy beneath it' do
      ::Groups::UpdateService.new(group, owner, path: 'renamed').execute

      event = moves.sole
      expect(event.project_path).to eq('renamed')
      expect(event.payload).to include(
        'namespace_type' => 'Group', 'old_path' => 'source', 'namespace_id' => group.id,
        'project_ids' => [nested_project.id], 'subgroup_ids' => [subgroup.id])
    end

    it 'keeps the parent in a subgroup\'s old path' do
      ::Groups::UpdateService.new(subgroup, owner, path: 'kid').execute

      expect(moves.sole.payload).to include('old_path' => 'source/child')
      expect(moves.sole.project_path).to eq('source/kid')
    end

    # TransferService reloads the group before its transaction commits, which
    # clears previous_changes; this is the case a commit-only hook misses.
    it 'records a transfer, with the hierarchy under the new parent' do
      ::Groups::TransferService.new(group, owner).execute(target)

      event = moves.sole
      expect(event.project_path).to eq('target/source')
      expect(event.payload).to include(
        'old_path' => 'source', 'namespace_id' => group.id,
        'project_ids' => [nested_project.id], 'subgroup_ids' => [subgroup.id])
    end

    it 'records a transfer out to the top level' do
      ::Groups::TransferService.new(subgroup, owner).execute(nil)

      expect(moves.sole.payload).to include('old_path' => 'source/child')
      expect(moves.sole.project_path).to eq('child')
    end

    it 'records nothing for a name change that keeps the path' do
      ::Groups::UpdateService.new(group, owner, name: 'New name').execute

      expect(moves).to be_empty
    end

    it 'records nothing for a move that rolls back' do
      ::Group.transaction do
        group.update!(path: 'renamed')
        raise ActiveRecord::Rollback
      end
      group.reload.update!(name: 'Later')

      expect(moves).to be_empty
    end

    it 'records two moves in one transaction once, from the original path' do
      ::Group.transaction do
        group.update!(path: 'first')
        group.update!(path: 'second')
      end

      expect(moves.sole.payload).to include('old_path' => 'source')
      expect(moves.sole.project_path).to eq('second')
    end

    it 'still saves when recording raises' do
      allow(OC::Projects::CloudmapEvent).to receive(:record_for_namespace).and_raise(ActiveRecord::StatementInvalid)

      expect { group.update!(path: 'renamed') }.not_to raise_error
      expect(group.reload.full_path).to eq('renamed')
    end
  end

  # A project's own path change moves projects.updated_at, so the poll sees it.
  it 'records nothing for a project rename' do
    project = create(:project, namespace: create(:group, owners: owner))

    ::Projects::UpdateService.new(project, owner, path: 'renamed-project').execute

    expect(project.reload.path).to eq('renamed-project')
    expect(moves).to be_empty
  end

  it 'records nothing when a namespace is created' do
    create(:group)

    expect(moves).to be_empty
  end
end
