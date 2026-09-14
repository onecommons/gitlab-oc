# frozen_string_literal: true

require 'spec_helper'

require_migration!

RSpec.describe MigrateOCClustersToEnvironmentProviders, migration: :gitlab_main,
  feature_category: :continuous_delivery do
  let(:namespaces) { table(:namespaces) }
  let(:organizations) { table(:organizations) }
  let(:projects) { table(:projects) }
  let(:environments) { table(:environments) }
  let(:clusters) { table(:clusters) }
  let(:aws_providers) { table(:cluster_providers_aws) }
  let(:gcp_providers) { table(:cluster_providers_gcp) }
  let(:aws_roles) { table(:aws_roles) }
  let(:users) { table(:users) }
  let(:providers) { table(:oc_environment_providers) }

  let(:organization) { organizations.create!(name: 'oc', path: 'oc') }
  let(:namespace) do
    namespaces.create!(name: 'group', path: 'group', type: 'Group', organization_id: organization.id)
  end

  let(:project) do
    projects.create!(
      name: 'dashboard', path: 'dashboard', namespace_id: namespace.id,
      project_namespace_id: project_namespace.id, organization_id: organization.id
    )
  end

  let(:project_namespace) do
    namespaces.create!(name: 'dashboard', path: 'dashboard', type: 'Project', organization_id: organization.id)
  end

  let(:user) do
    users.create!(username: 'deployer', email: 'deployer@example.com', projects_limit: 10,
      organization_id: organization.id)
  end

  def create_environment(name)
    environments.create!(project_id: project.id, name: name, slug: name)
  end

  def create_cluster(environment_scope, platform_type: 2)
    clusters.create!(
      name: environment_scope, environment_scope: environment_scope, platform_type: platform_type,
      user_id: user.id, project_id: project.id, created_at: Time.current, updated_at: Time.current
    )
  end

  it 'copies an aws credential onto its environment and takes the external id from the user' do
    environment = create_environment('production')
    cluster = create_cluster('production')
    aws_providers.create!(
      cluster_id: cluster.id, region: 'eu-west-1', role_arn: 'arn:aws:iam::123456789012:role/Deploy',
      num_nodes: 1, status: 2, key_name: 'key', vpc_id: 'vpc', security_group_id: 'sg',
      instance_type: 'm5.large', created_at: Time.current, updated_at: Time.current
    )
    aws_roles.create!(user_id: user.id, role_external_id: 'external-1', created_at: Time.current,
      updated_at: Time.current)

    migrate!

    provider = providers.find_by(environment_id: environment.id)
    expect(provider).to have_attributes(
      provider: 1, project_id: project.id, region: 'eu-west-1',
      role_arn: 'arn:aws:iam::123456789012:role/Deploy', role_external_ref: 'external-1'
    )
  end

  it 'copies a gcp credential without its expired token' do
    environment = create_environment('staging')
    cluster = create_cluster('staging')
    gcp_providers.create!(
      cluster_id: cluster.id, gcp_project_id: 'unfurl-demo', zone: 'us-central1-a',
      num_nodes: 1, created_at: Time.current, updated_at: Time.current
    )

    migrate!

    provider = providers.find_by(environment_id: environment.id)
    expect(provider).to have_attributes(provider: 2, gcp_project: 'unfurl-demo', zone: 'us-central1-a')
    expect(provider.access_token).to be_nil
  end

  it 'skips a credential whose environment is gone, and still removes the cluster' do
    create_cluster('deleted-environment').tap do |cluster|
      gcp_providers.create!(
        cluster_id: cluster.id, gcp_project_id: 'orphan', zone: 'us-central1-a',
        num_nodes: 1, created_at: Time.current, updated_at: Time.current
      )
    end

    migrate!

    expect(providers.count).to eq(0)
    expect(clusters.count).to eq(0)
  end

  it 'leaves a real Kubernetes cluster alone' do
    create_environment('k8s')
    create_cluster('k8s', platform_type: 1)

    migrate!

    expect(providers.count).to eq(0)
    expect(clusters.count).to eq(1)
  end
end
