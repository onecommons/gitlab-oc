# frozen_string_literal: true

# OC Change -- the project foreign key nullifies on delete, which scans the
# table for every deleted project without this.
class AddIndexToOCCloudmapEventsProjectId < Gitlab::Database::Migration[2.3]
  milestone '19.3'
  disable_ddl_transaction!

  INDEX_NAME = 'index_oc_cloudmap_events_on_project_id'

  def up
    add_concurrent_index :oc_cloudmap_events, :project_id, name: INDEX_NAME
  end

  def down
    remove_concurrent_index_by_name :oc_cloudmap_events, INDEX_NAME
  end
end
