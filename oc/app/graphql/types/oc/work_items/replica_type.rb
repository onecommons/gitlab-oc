# frozen_string_literal: true

module Types
  module OC
    module WorkItems
      # rubocop: disable Graphql/AuthorizeTypes -- reached only through WorkItem, which authorizes read_work_item
      class ReplicaType < BaseObject
        graphql_name 'OCWorkItemReplica'
        description 'A read-only work item: a copy of one held by another instance, or one being transferred there.'

        field :source_web_url, GraphQL::Types::String, null: true,
          description: 'URL of the original on the instance that holds it. Null while a transfer is pending.'
        field :surrendered, GraphQL::Types::Boolean, null: false, method: :state_surrendered?,
          description: 'Whether the item is being transferred away, rather than imported.'
      end
      # rubocop: enable Graphql/AuthorizeTypes
    end
  end
end
