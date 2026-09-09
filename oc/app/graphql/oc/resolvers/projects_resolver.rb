# frozen_string_literal: true

module OC
  module Resolvers
    module ProjectsResolver
      extend ActiveSupport::Concern
      extend ::Gitlab::Utils::Override

      prepended do
        argument :unfurl_type, ::Types::OC::Projects::UnfurlTypeEnum,
          required: false,
          description: 'Filter projects by how they are classified by their Unfurl files.'
      end

      private

      override :finder_params
      def finder_params(args)
        super.merge(unfurl_type: args[:unfurl_type])
      end
    end
  end
end
