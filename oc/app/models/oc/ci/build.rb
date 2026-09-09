# frozen_string_literal: true

module OC
  module Ci
    module Build
      extend ::Gitlab::Utils::Override

      # A dashboard deployment carries its delay in the START_IN pipeline
      # variable, so the job's start_in is a variable reference rather than a
      # literal duration and has to be expanded before it can be parsed.
      override :options_scheduled_at
      def options_scheduled_at
        ::ChronicDuration.parse(
          ::ExpandVariables.expand(options[:start_in], -> { simple_variables.sort_and_expand_all })
        )&.seconds&.from_now
      end
    end
  end
end
