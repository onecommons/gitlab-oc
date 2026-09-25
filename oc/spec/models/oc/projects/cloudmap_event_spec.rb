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
