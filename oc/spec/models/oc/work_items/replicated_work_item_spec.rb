# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OC::WorkItems::ReplicatedWorkItem, feature_category: :source_code_management do
  let_it_be(:project) { create(:project) }

  describe 'associations' do
    it 'reaches the local issue through the generic accessor' do
      issue = create(:issue, project: project)
      replica = create(:oc_replicated_work_item, project: project, issue: issue)

      expect(replica.work_item).to eq(issue)
      expect(issue.reload.oc_replica).to eq(replica)
    end

    it 'reaches the local merge request through the generic accessor' do
      merge_request = create(:merge_request)
      replica = create(:oc_replicated_work_item, :merge_request_kind,
        project: merge_request.target_project, merge_request: merge_request)

      expect(replica.work_item).to eq(merge_request)
      expect(merge_request.reload.oc_replica).to eq(replica)
    end

    it 'has no local record while deferred' do
      replica = create(:oc_replicated_work_item, :deferred, :merge_request_kind, project: project)

      expect(replica.work_item).to be_nil
      expect(replica).to be_state_deferred
    end

    it 'refuses a work_item that is neither an issue nor a merge request' do
      expect { described_class.new.work_item = project }.to raise_error(ArgumentError)
    end
  end

  # The reason the foreign keys nullify rather than cascade: an update is done
  # by rebuilding, which destroys the replica. If the row went with it we would
  # lose source_blob_oid -- the only record that this file was ever imported --
  # and the next reconcile would import a second copy.
  describe 'when the local record is destroyed' do
    it 'keeps the row and its reconcile state, clearing only the link' do
      issue = create(:issue, project: project)
      replica = create(:oc_replicated_work_item, project: project, issue: issue,
        source_blob_oid: 'a' * 40)

      issue.destroy!

      expect(replica.reload.issue_id).to be_nil
      expect(replica.source_blob_oid).to eq('a' * 40)
      expect(replica.work_item).to be_nil
    end
  end

  describe 'uniqueness' do
    it 'rejects a second row for the same source file in the same project' do
      first = create(:oc_replicated_work_item, project: project)

      duplicate = described_class.new(
        first.attributes.except('id', 'created_at', 'updated_at'))

      expect(duplicate).not_to be_valid
      expect { duplicate.save!(validate: false) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'allows the same source path from a different instance' do
      first = create(:oc_replicated_work_item, project: project)

      expect do
        create(:oc_replicated_work_item, project: project,
          source_instance_uuid: '99999999-8888-7777-6666-555555555555',
          source_path: first.source_path)
      end.not_to raise_error
    end

    it 'rejects two replicas pointing at the same local issue' do
      issue = create(:issue, project: project)
      create(:oc_replicated_work_item, project: project, issue: issue)

      expect do
        create(:oc_replicated_work_item, project: project, issue: issue,
          source_path: 'other/issues/1.yml')
      end.to raise_error(ActiveRecord::RecordNotUnique)
    end

    # The index that enforces the above is partial, so it must not stop several
    # rows from waiting with no local record at all.
    it 'allows many rows with no local record' do
      expect do
        create_list(:oc_replicated_work_item, 3, :deferred, :merge_request_kind, project: project)
      end.not_to raise_error
    end
  end

  describe 'validations' do
    it 'requires the fields the reconcile depends on' do
      replica = described_class.new(project: project)

      expect(replica).not_to be_valid
      expect(replica.errors.attribute_names)
        .to include(:source_instance_uuid, :source_path, :source_blob_oid, :source_iid)
    end
  end
end
