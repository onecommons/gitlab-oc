# frozen_string_literal: true

# OC is an acronym inflection, so oc_environment_providers camelizes with it.
class CreateOCEnvironmentProviders < Gitlab::Database::Migration[2.3]
  milestone '19.3'

  def change
    create_table :oc_environment_providers do |t|
      t.references :environment, null: false, index: { unique: true },
        foreign_key: { to_table: :environments, on_delete: :cascade }

      # Sharding key. Denormalised from the environment so the row carries one
      # without a join.
      t.references :project, null: false, index: true,
        foreign_key: { to_table: :projects, on_delete: :cascade }

      t.integer :provider, limit: 2, null: false

      t.datetime_with_timezone :access_token_expires_at
      t.timestamps_with_timezone null: false

      t.text :region, limit: 255
      t.text :role_arn, limit: 2048
      # The AWS ExternalId, copied off the creating user's aws_roles row:
      # gitlab_main_org may only reference gitlab_main, and users is
      # gitlab_main_user, so there is no user to join to. Named _ref rather
      # than _id because spec/db/schema_spec.rb demands a foreign key for every
      # column ending in _id.
      t.text :role_external_ref, limit: 64
      t.text :zone, limit: 255
      # Likewise not gcp_project_id.
      t.text :gcp_project, limit: 63

      t.jsonb :access_token
    end
  end
end
