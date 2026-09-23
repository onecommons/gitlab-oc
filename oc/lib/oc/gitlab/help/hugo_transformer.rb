# frozen_string_literal: true

module OC
  module Gitlab
    module Help
      module HugoTransformer
        extend ::Gitlab::Utils::Override

        # `details` names the tier and offering of a GitLab plan. `history`
        # dates a feature against GitLab's releases, and upstream turns it into
        # a heading, which the fork's help typography renders as a banner above
        # the page's own first line. Close to 700 pages carry one or the other.
        DROPPED_SHORTCODES = %w[details history].freeze

        DROPPED_PATTERN = ::Regexp.union(
          DROPPED_SHORTCODES.map do |name|
            %r{\{\{<\s*#{name}\s*>\}\}.*?\{\{<\s*/#{name}\s*>\}\}\n*}m
          end
        )

        private

        # Upstream's handler builds the heading. Leave the shortcode alone and
        # let the sweep below take the whole block.
        override :handle_history_shortcodes
        def handle_history_shortcodes(content)
          content
        end

        # A shortcode upstream has no handler for keeps its body, which is how
        # `details` leaked its list onto every page.
        override :remove_generic_shortcodes
        def remove_generic_shortcodes(content)
          content.gsub!(DROPPED_PATTERN, '')
          super
        end
      end
    end
  end
end
