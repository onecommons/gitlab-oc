# frozen_string_literal: true

module OC
  module Namespaces
    module ServiceAccounts
      module BaseCreateService
        extend ActiveSupport::Concern
        extend ::Gitlab::Utils::Override

        # Upstream caps unlicensed instances at Authn::ServiceAccounts::LIMIT_FOR_FREE
        # (100) counted across the whole instance, so one group can exhaust the
        # allowance for every other group. That limit stands in for a tier this
        # edition does not have; what is worth bounding is a single hierarchy.
        LIMIT_PER_ROOT_NAMESPACE = 50

        private

        # Counted over the root ancestor rather than the group the request names,
        # so the limit cannot be sidestepped by creating a subgroup. Both group-
        # and project-provisioned accounts count, because a project's service
        # accounts belong to the same hierarchy's allowance.
        override :creation_allowed?
        def creation_allowed?
          return true unless root_namespace

          LIMIT_PER_ROOT_NAMESPACE > service_accounts_in_hierarchy_count
        end

        def service_accounts_in_hierarchy_count
          namespace_ids = root_namespace.self_and_descendant_ids

          by_group = ::User.service_accounts.with_provisioning_group(namespace_ids)
          by_project = ::User.service_accounts.with_provisioning_project_in(namespace_ids)

          ::User.from_union([by_group.select(:id), by_project.select(:id)],
            remove_duplicates: false).count
        end
      end
    end
  end
end
