# frozen_string_literal: true

# OC is an acronym inflection, so the OC prefix camelizes with it.
class MigrateOCClustersToEnvironmentProviders < Gitlab::Database::Migration[2.3]
  milestone '19.3'
  restrict_gitlab_migration gitlab_schema: :gitlab_main_org
  # The copy and the delete lock different tables, so they cannot share one
  # transaction. Re-running is safe: the insert conflicts away and the delete
  # only ever matches the fork's own rows.
  disable_ddl_transaction!

  # The fork wrote every cloud credential as a cluster with this platform_type,
  # which 19.3's enum no longer defines. Nothing provisioned them.
  UNFURL_PLATFORM_TYPE = 2

  AWS = 1
  GCP = 2

  def up
    external_refs = role_external_refs

    unfurl_clusters.each do |cluster|
      insert_provider(cluster, external_refs[cluster['user_id']])
    end

    # Including the ones nothing was copied from: Clusters::Cluster cannot load
    # a platform_type it does not define, so leaving them is worse than the
    # loss. cluster_projects and the provider rows cascade.
    execute("DELETE FROM clusters WHERE platform_type = #{UNFURL_PLATFORM_TYPE}")
  end

  def down
    # The copy drops the expired OAuth token and the provisioning placeholders.
    # There is nothing faithful to restore.
  end

  private

  # Joined to environments by name, which is what environment_scope held: the
  # fork set it to the environment the credential belonged to. A cluster whose
  # environment is gone is not copied.
  def unfurl_clusters
    execute_read(<<~SQL)
      SELECT c.user_id,
             c.project_id,
             c.created_at,
             c.updated_at,
             e.id AS environment_id,
             CASE WHEN a.cluster_id IS NOT NULL THEN #{AWS} ELSE #{GCP} END AS provider,
             a.region,
             a.role_arn,
             g.zone,
             g.gcp_project_id
      FROM clusters c
      INNER JOIN environments e
        ON e.project_id = c.project_id AND e.name = c.environment_scope
      LEFT JOIN cluster_providers_aws a ON a.cluster_id = c.id
      LEFT JOIN cluster_providers_gcp g ON g.cluster_id = c.id
      WHERE c.platform_type = #{UNFURL_PLATFORM_TYPE}
        AND c.project_id IS NOT NULL
        AND (a.cluster_id IS NOT NULL OR g.cluster_id IS NOT NULL)
    SQL
  end

  # Read on its own rather than joined: aws_roles is gitlab_main_user, which
  # gitlab_main_org may not join to.
  def role_external_refs
    execute_read('SELECT user_id, role_external_id FROM aws_roles')
      .to_h { |row| [row['user_id'], row['role_external_id']] }
  end

  def insert_provider(cluster, external_ref)
    values = {
      environment_id: cluster['environment_id'],
      project_id: cluster['project_id'],
      provider: cluster['provider'],
      region: cluster['region'],
      role_arn: cluster['role_arn'],
      role_external_ref: (external_ref if cluster['provider'] == AWS),
      zone: cluster['zone'],
      gcp_project: cluster['gcp_project_id'],
      created_at: cluster['created_at'],
      updated_at: cluster['updated_at']
    }

    execute(<<~SQL)
      INSERT INTO oc_environment_providers (#{values.keys.join(', ')})
      VALUES (#{values.values.map { |value| connection.quote(value) }.join(', ')})
      ON CONFLICT (environment_id) DO NOTHING
    SQL
  end

  def execute_read(sql)
    connection.select_all(sql)
  end
end
