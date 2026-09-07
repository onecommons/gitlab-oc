# frozen_string_literal: true

# OC is an acronym inflection, so oc_replicated_work_items camelizes with it.
class CreateOCReplicatedWorkItems < Gitlab::Database::Migration[2.3]
  milestone '19.3'

  def change
    create_table :oc_replicated_work_items do |t|
      t.references :project, null: false, index: false,
        foreign_key: { to_table: :projects, on_delete: :cascade }

      # Nullable because a deferred row has no local record yet; nullify rather
      # than cascade so a rebuild that destroys the replica keeps the row. Two
      # columns rather than a polymorphic pair so both carry a real foreign key.
      t.references :issue, null: true, index: false,
        foreign_key: { to_table: :issues, on_delete: :nullify }
      t.references :merge_request, null: true, index: false,
        foreign_key: { to_table: :merge_requests, on_delete: :nullify }

      t.integer :source_kind, limit: 2, null: false
      t.integer :state, limit: 2, null: false, default: 0
      t.integer :source_iid, null: false

      t.timestamps_with_timezone null: false

      t.text :source_instance_uuid, null: false, limit: 255
      t.text :source_path, null: false, limit: 1024
      t.text :source_blob_oid, null: false, limit: 64
      t.text :source_web_url, limit: 2048
      t.text :reason, limit: 255
      # JSON in text rather than jsonb: see OC::WorkItems::ReplicatedWorkItem.
      # rubocop:disable Migration/PreventLargeBlobInDatabase -- written once per import and read once when the reference file is published; a project-wide identity map does not fit in 4096 characters
      t.text :identity_map, limit: 65_536
      t.text :unresolved_refs, limit: 8192
      # rubocop:enable Migration/PreventLargeBlobInDatabase

      t.index %i[project_id source_instance_uuid source_path], unique: true,
        name: 'index_oc_replicated_work_items_on_source'
      # Partial, because deferred rows have no local record yet.
      t.index :issue_id, unique: true, where: 'issue_id IS NOT NULL',
        name: 'index_oc_replicated_work_items_on_issue_id'
      t.index :merge_request_id, unique: true, where: 'merge_request_id IS NOT NULL',
        name: 'index_oc_replicated_work_items_on_merge_request_id'
    end
  end
end
