# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OC::Projects::CloudmapEvent, feature_category: :source_code_management do
  let_it_be(:project) { create(:project) }

  describe '.record_for' do
    it 'takes the organization and path from the project' do
      event = described_class.record_for(project, kind: :visibility_changed,
        payload: { visibility_level: 0 })

      expect(event.organization_id).to eq(project.organization_id)
      expect(event.project_path).to eq(project.full_path)
      expect(event.project).to eq(project)
      expect(event).to be_visibility_changed
    end

    # jsonb round-trips through JSON, so a symbol key reads back as a string.
    # Asserted rather than assumed: a consumer reads these keys.
    it 'stores the payload with string keys' do
      event = described_class.record_for(project, kind: :visibility_changed,
        payload: { visibility_level: 0 })

      expect(event.reload.payload).to eq('visibility_level' => 0)
    end
  end

  describe '.record_deletion' do
    it 'keeps the path with no project to point at' do
      event = described_class.record_deletion('group/gone', project.organization_id,
        payload: { visibility: 'public', web_url: 'https://example.com/group/gone' })

      expect(event.project).to be_nil
      expect(event.project_path).to eq('group/gone')
      expect(event).to be_project_deleted
      expect(event.payload)
        .to eq('visibility' => 'public', 'web_url' => 'https://example.com/group/gone')
    end

    it 'drops a key with no value rather than storing null' do
      event = described_class.record_deletion('group/gone', project.organization_id,
        payload: { visibility: 'public', web_url: nil })

      expect(event.payload).to eq('visibility' => 'public')
    end
  end

  describe '.namespace_snapshot' do
    let_it_be(:group) { create(:group) }
    let_it_be(:subgroup) { create(:group, parent: group) }
    let_it_be(:nested_project) { create(:project, namespace: subgroup) }

    it 'lists the whole hierarchy of a group' do
      snapshot = described_class.namespace_snapshot(group)

      expect(snapshot).to include(full_path: group.full_path, organization_id: group.organization_id)
      # Each project has a namespace of its own; only groups are listed.
      expect(snapshot[:payload]).to include(
        namespace_id: group.id, project_ids: [nested_project.id], subgroup_ids: [subgroup.id])
    end

    it 'has no subgroup list for a user namespace' do
      user = create(:user, :with_namespace)
      project = create(:project, namespace: user.namespace)

      payload = described_class.namespace_snapshot(user.namespace)[:payload]

      expect(payload).to include(project_ids: [project.id], subgroup_ids: nil)
    end
  end

  describe '.record_for_namespace' do
    let_it_be(:group) { create(:group) }

    it 'keys the row on the namespace with no project' do
      event = described_class.record_for_namespace(
        described_class.namespace_snapshot(group), kind: :group_archived)

      expect(event.project).to be_nil
      expect(event.project_path).to eq(group.full_path)
      expect(event.organization_id).to eq(group.organization_id)
      expect(event.payload).to include('namespace_id' => group.id, 'project_ids' => [], 'subgroup_ids' => [])
    end
  end

  describe '.record_for_namespace_quietly' do
    it 'logs rather than raising' do
      snapshot = { full_path: 'a', organization_id: nil, payload: { namespace_id: 1 } }
      expect(::Gitlab::AppLogger).to receive(:warn).with(hash_including(namespace_id: 1))

      expect(described_class.record_for_namespace_quietly(snapshot, kind: :group_deleted)).to be_nil
    end
  end

  describe '.record_metadata_changes' do
    it 'writes one row per project in one insert' do
      other = create(:project)

      described_class.record_metadata_changes([project, other], changed: %w[topics])

      rows = described_class.metadata_changed.order(:id)
      expect(rows.map(&:project_id)).to eq([project.id, other.id])
      expect(rows.first.project_path).to eq(project.full_path)
      expect(rows.first.payload).to eq(
        'visibility' => project.visibility, 'web_url' => project.web_url, 'changed' => %w[topics])
    end
  end

  describe '.cursor_since' do
    it 'starts just before the first row since the time given' do
      create(:oc_cloudmap_event, project: project, occurred_at: 2.days.ago)
      recent = create(:oc_cloudmap_event, project: project, occurred_at: 1.hour.ago)

      expect(described_class.cursor_since(1.day.ago)).to eq(recent.id - 1)
    end

    it 'starts after the last row when none is that recent' do
      old = create(:oc_cloudmap_event, project: project, occurred_at: 2.days.ago)

      expect(described_class.cursor_since(1.day.ago)).to eq(old.id)
    end
  end

  describe '.after_cursor' do
    it 'returns later rows in id order' do
      first = create(:oc_cloudmap_event, project: project)
      second = create(:oc_cloudmap_event, project: project)

      expect(described_class.after_cursor(first.id)).to eq([second])
    end
  end

  # The sharding key cannot be null, which is why a row is keyed on the
  # organization rather than the project it describes. Enforced by the column
  # rather than a validation, so this is the database refusing it.
  it 'refuses a row with no organization' do
    expect do
      described_class.create!(kind: :project_deleted, project_path: 'a/b', occurred_at: Time.current)
    end.to raise_error(ActiveRecord::NotNullViolation)
  end
end
