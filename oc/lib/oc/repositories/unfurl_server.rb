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
      BROWSER_ENV_KEY = 'UNFURL_SERVER_URL'
      # The GDK service oc/scripts/unfurl.rb defines.
      GDK_URL = 'http://localhost:8081'

      class << self
        def internal_url
          ENV[ENV_KEY].presence ||
            config['unfurl_server_internal_url'].presence ||
            browser_url
        end

        # What gon hands oc-pages. Unset when the page uses the same-origin
        # proxy path, which is the ordinary production case.
        def browser_url
          ENV[BROWSER_ENV_KEY].presence || config['unfurl_server_url'].presence || development_default
        end

        # Lets the browser reach a server outside GitLab's origin, as on a GDK.
        # Appends, because setting connect_src in gitlab.yml replaces the whole
        # default, dev servers included.
        def allow_in_csp(policy)
          url = browser_url
          sources = policy&.directives&.fetch('connect-src', nil)
          return if url.blank? || sources.blank?

          origin = URI.join(url, '/').to_s
          policy.connect_src(*sources, origin) unless sources.include?(origin)
        end

        private

        def development_default
          GDK_URL if Rails.env.development?
        end

        def config
          ::Gitlab.config.extra
        end
      end
    end
  end
end
