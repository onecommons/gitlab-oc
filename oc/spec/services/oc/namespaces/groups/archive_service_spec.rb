# frozen_string_literal: true

require 'spec_helper'

# Archive and unarchive publish the same upstream event, so each direction is
# recorded by its own service override. Both are exercised here.
RSpec.describe OC::Namespaces::Groups::ArchiveService, feature_category: :groups_and_projects do
  let_it_be(:owner) { create(:user) }
  let!(:group) { create(:group, :public, owners: owner) }
  let!(:subgroup) { create(:group, parent: group) }
  let!(:project) { create(:project, namespace: group) }
  let!(:nested_project) { create(:project, namespace: subgroup) }

  let(:archive) { ::Namespaces::Groups::ArchiveService.new(group, owner).execute }
  let(:unarchive) { ::Namespaces::Groups::UnarchiveService.new(group, owner).execute }

  it 'records the archive with the whole hierarchy' do
    expect { archive }.to change { OC::Projects::CloudmapEvent.count }.by(1)

    event = OC::Projects::CloudmapEvent.last
    expect(event).to be_group_archived
    expect(event.project).to be_nil
    expect(event.project_path).to eq(group.full_path)
    expect(event.organization_id).to eq(group.organization_id)
    expect(event.payload).to eq(
      'visibility' => 'public', 'web_url' => group.web_url, 'namespace_id' => group.id,
      'project_ids' => [project.id, nested_project.id].sort,
      'subgroup_ids' => [subgroup.id])
  end

  it 'records the unarchive as its own kind' do
    archive

    expect { unarchive }.to change { OC::Projects::CloudmapEvent.count }.by(1)
    expect(OC::Projects::CloudmapEvent.last).to be_group_unarchived
  end

  it 'records nothing when the archive is refused' do
    outsider = create(:user)

    expect { ::Namespaces::Groups::ArchiveService.new(group, outsider).execute }
      .not_to change { OC::Projects::CloudmapEvent.count }
  end

  it 'still succeeds when recording raises' do
    allow(OC::Projects::CloudmapEvent).to receive(:record_for_namespace).and_raise(ActiveRecord::StatementInvalid)

    expect(archive).to be_success
  end
end
