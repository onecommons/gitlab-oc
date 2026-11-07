# frozen_string_literal: true

# OC is an acronym inflection, so oc_work_item_drafts camelizes with it.
class CreateOCWorkItemDrafts < Gitlab::Database::Migration[2.3]
  milestone '19.3'

  def change
    create_table :oc_work_item_drafts do |t|
      t.references :project, null: false, index: false,
        foreign_key: { to_table: :projects, on_delete: :cascade }

      # Nullify rather than cascade: a key stays spent after its issue is
      # deleted, so a stale copy of the draft is removed instead of recreated.
      t.references :issue, null: true, index: false,
        foreign_key: { to_table: :issues, on_delete: :nullify }

      # Copied at creation, so drafts.yml keeps saying what the key became.
      t.integer :iid, null: false

      t.timestamps_with_timezone null: false

      t.text :key, null: false, limit: 64

      t.index %i[project_id key], unique: true, name: 'index_oc_work_item_drafts_on_project_id_and_key'
      t.index :issue_id, unique: true, where: 'issue_id IS NOT NULL',
        name: 'index_oc_work_item_drafts_on_issue_id'
    end
  end
end
