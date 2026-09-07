# frozen_string_literal: true

module OC
  module Types
    module WorkItemType
      extend ActiveSupport::Concern

      prepended do
        field :oc_replica, ::Types::OC::WorkItems::ReplicaType, null: true,
          description: 'Why the work item is read-only: a copy of an item held by another instance, ' \
            'or an item being transferred to one. Null for an ordinary work item.'
      end

      def oc_replica
        replica = object.oc_replica
        replica if replica&.read_only?
      end
    end
  end
end
