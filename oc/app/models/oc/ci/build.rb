# frozen_string_literal: true

module OC
  module Ci
    module Build
      extend ::Gitlab::Utils::Override

      # Deployment jobs into an environment with a cloud provider run with that
      # account's credentials.
      #
      # Memoized on its own key: upstream memoizes its result and
      # Collection#concat mutates its receiver, so this has to build a copy, and
      # the AWS branch is a request to STS that must not be repeated.
      override :variables
      # rubocop: disable Gitlab/StrongMemoizeAttr -- needs a key of its own; upstream's method memoizes on :variables
      def variables
        strong_memoize(:oc_variables) do
          ::Gitlab::Ci::Variables::Collection.new.concat(super).concat(unfurl_provider_variables)
        end
      end
      # rubocop: enable Gitlab/StrongMemoizeAttr

      # A dashboard deployment carries its delay in the START_IN pipeline
      # variable, so the job's start_in is a variable reference rather than a
      # literal duration and has to be expanded before it can be parsed.
      override :options_scheduled_at
      def options_scheduled_at
        ::ChronicDuration.parse(
          ::ExpandVariables.expand(options[:start_in], -> { simple_variables.sort_and_expand_all })
        )&.seconds&.from_now
      end

      private

      def unfurl_provider_variables
        provider = deployment&.environment&.unfurl_provider
        return ::Gitlab::Ci::Variables::Collection.new unless provider

        provider.ci_variables
      end
    end
  end
end
