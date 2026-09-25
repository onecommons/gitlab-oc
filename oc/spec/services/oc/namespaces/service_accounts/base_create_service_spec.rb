# frozen_string_literal: true

require 'spec_helper'

# The override lives on BaseCreateService but is only reachable through a
# subclass, so it is exercised here through the group entry point.
RSpec.describe OC::Namespaces::ServiceAccounts::BaseCreateService, feature_category: :user_management do
  let_it_be(:organization) { create(:organization) }
  let_it_be(:group) { create(:group, organization: organization) }
  let_it_be(:subgroup) { create(:group, parent: group, organization: organization) }
  let_it_be(:owner) { create(:user, owner_of: group) }

  let(:limit) { OC::Namespaces::ServiceAccounts::BaseCreateService::LIMIT_PER_ROOT_NAMESPACE }

  subject(:result) do
    ::Namespaces::ServiceAccounts::GroupCreateService
      .new(owner, { organization_id: organization.id, namespace_id: group.id })
      .execute
  end

  def provision(count, **attrs)
    create_list(:user, count, :service_account, organization: organization) do |user|
      user.user_detail.update!(attrs)
    end
  end

  it 'allows creation below the limit' do
    provision(1, provisioned_by_group: group)

    expect(result.status).to eq(:success)
  end

  it 'refuses once the hierarchy is at the limit' do
    provision(limit, provisioned_by_group: group)

    expect(result.status).to eq(:error)
    expect(result.message).to include('limit')
  end

  # The point of the override: upstream counts every service account on the
  # instance, so a busy group used up everyone else's allowance. Stubbing the
  # instance-wide check to refuse is what makes this discriminating -- without
  # the override the result would be an error regardless of which group the
  # other accounts belong to.
  it 'ignores accounts belonging to another hierarchy' do
    other = create(:group, organization: organization)
    provision(2, provisioned_by_group: other)
    allow(Authn::ServiceAccounts).to receive(:creation_allowed_for_sm?).and_return(false)

    expect(result.status).to eq(:success)
  end

  # Counted on the root ancestor, so a subgroup cannot be used to start a fresh
  # allowance.
  it 'counts accounts provisioned by a subgroup' do
    provision(limit, provisioned_by_group: subgroup)

    expect(result.status).to eq(:error)
  end

  it 'counts accounts provisioned by a project in the hierarchy' do
    project = create(:project, namespace: subgroup, organization: organization)
    provision(limit, provisioned_by_project: project)

    expect(result.status).to eq(:error)
  end
end
