# frozen_string_literal: true

module GDK
  module Services
    # The Unfurl server the blueprint and dashboard pages call. Production
    # proxies it behind the chart's Ingress; a GDK reaches it directly, so it
    # runs with CORS for the GitLab origin, and in development
    # OC::Repositories::UnfurlServer::GDK_URL points at it.
    #
    # Run as production runs it (docker/aux/server-entrypoint.sh in unfurl):
    # unfurl-server here, in front of the Python backend (UnfurlBackend).
    # Not `unfurl serve`, whose UNFURL_SERVE_PATH puts unfurl-server in dev
    # mode, which never pushes the cloudmap.
    class Unfurl < Base
      PORT = 8081
      BACKEND_PORT = 8082

      def name
        'unfurl'
      end

      # The digest is part of the ETags both servers compute, so it is read
      # at each start, as the backend reads its own.
      def command
        digest = "#{bin('python')} -c 'from unfurl.util import get_package_digest; print(get_package_digest())'"
        %(sh -c "UNFURL_PACKAGE_DIGEST=\\$(#{digest}) exec #{bin('unfurl-server')}")
      end

      def env
        base = shared_env.merge(
          'UNFURL_HOST' => 'localhost',
          'UNFURL_PORT' => PORT.to_s,
          'UNFURL_BACKEND_URL' => "http://localhost:#{BACKEND_PORT}",
          'RUST_LOG' => 'info,unfurl_server=debug',
          # who it commits as; the backend names itself
          'GIT_AUTHOR_NAME' => 'unfurl unfurl-server',
          'GIT_COMMITTER_NAME' => 'unfurl unfurl-server',
          'GIT_AUTHOR_EMAIL' => 'unfurl-unfurl-server+noreply@unfurl.cloud',
          'GIT_COMMITTER_EMAIL' => 'unfurl-unfurl-server+noreply@unfurl.cloud'
        )
        # The install script writes the key after creating the database, so
        # the URL is offered only once there is one. With no repo the server
        # clones onecommons/cloudmap's main under the clone root itself, the
        # only checkouts it pushes; /cloudmap is proxied to Python without it.
        return base unless grant_key_file.file?

        base.merge(
          'UNFURL_CLOUDMAP_DB_URL' => cloudmap_db_url,
          'UNFURL_GRANT_KEY_FILE' => grant_key_file
        )
      end

      def enabled?
        true
      end

      def ready_message
        "Unfurl server is available at http://#{config.hostname}:#{PORT}"
      end

      private

      # What both processes read, as `unfurl serve` set it for both.
      def shared_env
        {
          'UNFURL_HOME' => home.to_s,
          'UNFURL_CLONE_ROOT' => clone_root.to_s,
          'UNFURL_CLOUD_SERVER' => gitlab_url,
          'UNFURL_SERVE_CORS' => gitlab_url,
          'UNFURL_LOGGING' => 'trace',
          'UNFURL_PACKAGE_RULES' => package_rules,
          'CACHE_REDIS_URL' => cache_redis_url
        }
      end

      # Links the install script makes to unfurl's Python and its
      # unfurl-server build, so a rebuild needs only a restart.
      def bin(name)
        GDK.root.join('tmp', 'unfurl_bin', name)
      end

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
      # parameter rather than in the authority. The role and database are
      # repeated in oc/scripts/install_gdk_unfurl.sh; a mismatch migrates an
      # empty database and serves an empty index rather than failing. Override
      # the whole URL in env.runit, which the run script sources after this.
      def cloudmap_db_url
        "postgres://unfurl_cloudmap@localhost/unfurl_cloudmap?host=#{config.postgresql.host}"
      end

      # A home of the GDK's own rather than ~/.unfurl_home: a repository
      # redirect in a personal home's local unfurl.yaml makes every environment
      # importing std fail to export, and one unexportable environment disables
      # environment creation entirely. It holds the cloudmaps.hosts entry that
      # lets POST /cloudmap/analyze read this GitLab's projects.
      def home
        GDK.root.join('tmp', 'unfurl_home')
      end

      def clone_root
        GDK.root.join('tmp', 'repos')
      end

      # Encrypts the credentials the server keeps to push with.
      def grant_key_file
        GDK.root.join('tmp', 'unfurl_grant_key')
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
