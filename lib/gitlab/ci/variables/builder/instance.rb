# frozen_string_literal: true

module Gitlab
  module Ci
    module Variables
      class Builder
        class Instance
          include Gitlab::Utils::StrongMemoize

          # rubocop: disable Lint/UnusedMethodArgument -- callers name the keyword; the fork ignores it
          def secret_variables(protected_ref: false, only: nil)
            # OC Change: instance protected variables are not exposed to any job,
            # protected ref or not, so protected_ref is deliberately unused.
            variables = ::Ci::InstanceVariable.unprotected_cached

            # Due to caching logic these variables are an array so we can't use ActiveRecord.where
            variables = variables.filter { |v| only.nil? || v.key.in?(only) }

            Gitlab::Ci::Variables::Collection.new(variables)
          end
          # rubocop: enable Lint/UnusedMethodArgument
        end
      end
    end
  end
end
