# frozen_string_literal: true

module OC
  module Gitlab
    module Auth
      extend ::Gitlab::Utils::Override

      # An Unfurl deployment runs as a CI job and commits its results back to
      # the repository, so its job token needs to push. Upstream grants
      # build_push_code, which is not the same ability.
      override :build_authentication_abilities
      def build_authentication_abilities
        super + [:push_code]
      end
    end
  end
end
