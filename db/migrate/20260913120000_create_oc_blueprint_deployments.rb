# frozen_string_literal: true

# OC is an acronym inflection, so oc_blueprint_deployments camelizes with it.
class CreateOCBlueprintDeployments < Gitlab::Database::Migration[2.3]
  milestone '19.3'

  def change
    create_table :oc_blueprint_deployments do |t|
      t.references :blueprint_project, null: false, index: true,
        foreign_key: { to_table: :projects, on_delete: :cascade }

      # The project whose pipeline deployed it. Indexed only as half of the
      # dedupe key below; nothing counts by it yet.
      t.references :deployed_project, null: false, index: false,
        foreign_key: { to_table: :projects, on_delete: :cascade }

      t.datetime_with_timezone :finished_at, null: false

      # Dedupe rather than audit. Ci::PipelineFinishedEvent is delivered at
      # least once, and a redelivery carries the same finished_at, so a replay
      # collides here instead of counting twice. The pipeline id would say more
      # but lives in another database, where it could carry no foreign key and
      # would need an IGNORED_FK_COLUMNS entry in an upstream spec.
      t.index [:deployed_project_id, :finished_at], unique: true,
        name: 'index_oc_blueprint_deployments_on_deployed_project_and_time'
    end
  end
end
