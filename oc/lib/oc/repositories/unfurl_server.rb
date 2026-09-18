# frozen_string_literal: true

module OC
  module Repositories
    # Where to reach the Unfurl server, which differs by who is asking: a
    # browser goes through whatever fronts it, and in production that is a load
    # balancer which authenticates, while GitLab's own calls go to the
    # container behind it.
    #
    # The environment variable is for deployments that cannot set the `extra`
    # key. Both fall back to the browser's URL, so one address stays enough
    # wherever nothing sits in front of the server.
    module UnfurlServer
      ENV_KEY = 'UNFURL_SERVER_INTERNAL_URL'

      class << self
        def internal_url
          ENV[ENV_KEY].presence ||
            config['unfurl_server_internal_url'].presence ||
            browser_url
        end

        private

        # What gon hands oc-pages. Unset when the page uses the same-origin
        # proxy path, which is the ordinary production case.
        def browser_url
          config['unfurl_server_url'].presence
        end

        def config
          ::Gitlab.config.extra
        end
      end
    end
  end
end
