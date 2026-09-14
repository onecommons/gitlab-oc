# frozen_string_literal: true

module OC
  module Types
    module ProjectType
      extend ActiveSupport::Concern

      prepended do
        field :blueprint_deployment_count, GraphQL::Types::Int, null: false,
          description: 'How many times this blueprint has been deployed. Zero for a project ' \
            'nothing has been deployed from.'
      end

      # One query for a page of tiles rather than a count each.
      def blueprint_deployment_count
        ::BatchLoader::GraphQL.for(object.id).batch(default_value: 0) do |project_ids, loader|
          ::OC::Environments::BlueprintDeployment.counts_for(project_ids).each do |id, count|
            loader.call(id, count)
          end
        end
      end
    end
  end
end
