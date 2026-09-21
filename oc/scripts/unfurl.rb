# frozen_string_literal: true

module GDK
  module Services
    # The Unfurl server the blueprint and dashboard pages call. Production
    # proxies it behind the chart's Ingress; a GDK reaches it directly, so it
    # runs with CORS for the GitLab origin and gitlab.yml's
    # extra.unfurl_server_url points at it.
    class Unfurl < Base
      PORT = 8081

      def name
        'unfurl'
      end

      def command
        "unfurl serve --clone-root #{clone_root} --cloud-server #{gitlab_url} " \
          "--port #{PORT} --cors #{gitlab_url}"
      end

      def env
        base = {
          # With a home project, a repository redirect in its local unfurl.yaml
          # makes every environment importing std fail to export, and one
          # unexportable environment disables environment creation entirely.
          'UNFURL_HOME' => '',
          'UNFURL_LOGGING' => 'trace',
          'UNFURL_PACKAGE_RULES' => package_rules,
          # Setting this also puts the Rust proxy in front of waitress; it binds
          # PORT and moves the Python backend behind it.
          'CACHE_REDIS_URL' => cache_redis_url
        }
        # The fast path needs the pair, and takes a working tree rather than a
        # URL -- the server exits non-zero when the path is not one, so offer
        # neither until the clone is there. /cloudmap is then proxied to Python.
        return base unless cloudmap_repo.directory?

        base.merge(
          'UNFURL_CLOUDMAP_REPO' => cloudmap_repo,
          'UNFURL_CLOUDMAP_DB_URL' => cloudmap_db_url
        )
      end

      def enabled?
        true
      end

      def ready_message
        "Unfurl server is available at http://#{config.hostname}:#{PORT}"
      end

      private

      # Whitespace-separated pairs: each package pattern followed by what it
      # resolves to, so onecommons packages come from this GDK. The second
      # replacement carries a scheme and the first does not, deliberately: a
      # value without "://" is read as another package id, which resolves
      # against the original host and appends rather than redirects.
      def package_rules
        [
          'gitlab.com/onecommons/*', 'unfurl.cloud/onecommons/*',
          'unfurl.cloud/onecommons/*', "#{gitlab_url}/onecommons/*"
        ].join(' ')
      end

      # GDK addresses redis by socket and gives no port setting. Databases 0-5
      # are GitLab's in development, per the redis component's own list.
      def cache_redis_url
        "unix://#{config.redis.__socket_file}?db=6"
      end

      # GDK's postgres listens on a socket only, which sqlx takes as a host
      # parameter rather than in the authority. The database name is repeated
      # in oc/scripts/install_gdk_unfurl.sh; a mismatch migrates an empty
      # database and serves an empty index rather than failing. Override the
      # whole URL in env.runit, which the run script sources after this.
      def cloudmap_db_url
        "postgres:///unfurl_cloudmap?host=#{config.postgresql.host}"
      end

      def clone_root
        GDK.root.join('tmp', 'repos')
      end

      def cloudmap_repo
        GDK.root.join('tmp', 'cloudmap')
      end

      def gitlab_url
        "http://#{gitlab_host}"
      end

      def gitlab_host
        "#{config.hostname}:#{config.gitlab.rails.port}"
      end
    end
  end
end
