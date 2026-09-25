# frozen_string_literal: true

# OC is an acronym inflection, so oc_cloudmap_events camelizes with it.
class CreateOCCloudmapEvents < Gitlab::Database::Migration[2.3]
  milestone '19.3'

  def change
    create_table :oc_cloudmap_events do |t|
      # Sharding key, and organizations rather than projects because a row has
      # to outlive the project it describes: a deletion tombstone is the only
      # record left of a project that is gone. A sharding key may not be null
      # (spec/lib/gitlab/organizations/sharding_key_spec.rb), which rules out
      # sharding on the project itself.
      t.references :organization, null: false, index: false,
        foreign_key: { to_table: :organizations, on_delete: :cascade }

      # Nullified when the project goes, which is the case project_path is
      # here for.
      t.references :project, null: true, index: false,
        foreign_key: { to_table: :projects, on_delete: :nullify }

      t.integer :kind, limit: 2, null: false
      t.datetime_with_timezone :occurred_at, null: false
      t.text :project_path, null: false, limit: 1024
      t.jsonb :payload

      # The primary key is the cursor a consumer pages on. This one is for a
      # feed scoped to a single organization.
      t.index [:organization_id, :id]

      # For the pruner, which is the only reader that does not page on the
      # primary key.
      t.index :occurred_at
    end
  end
end
