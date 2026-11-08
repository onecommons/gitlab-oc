# frozen_string_literal: true

# Peers' items are matched by number rather than by file path, since a file's
# name is for people and can change.
class AddSourceIidIndexToOCReplicatedWorkItems < Gitlab::Database::Migration[2.3]
  disable_ddl_transaction!

  milestone '19.3'

  INDEX_NAME = 'index_oc_replicated_work_items_on_source_iid'

  def up
    add_concurrent_index :oc_replicated_work_items,
      [:project_id, :source_instance_uuid, :source_kind, :source_iid], name: INDEX_NAME
  end

  def down
    remove_concurrent_index_by_name :oc_replicated_work_items, INDEX_NAME
  end
end
