# frozen_string_literal: true

module OC
  module Repository
    extend ActiveSupport::Concern

    UNFURL_METHODS = %i[unfurl_yaml ensemble_template_yaml].freeze

    prepended do
      # Defined on the class rather than in this module so that cache_method
      # wraps them: a module method would sit in front of the wrapper.
      def ensemble_template_yaml
        ::Gitlab::GitalyClient.allow_n_plus_1_calls { file_on_head(:ensemble_template_yaml) }
      end
      cache_method :ensemble_template_yaml

      def unfurl_yaml
        ::Gitlab::GitalyClient.allow_n_plus_1_calls { file_on_head(:unfurl_yaml) }
      end
      cache_method :unfurl_yaml
    end

    def expire_unfurl_caches
      expire_method_caches(UNFURL_METHODS)
    end
  end
end
