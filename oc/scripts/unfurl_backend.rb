# frozen_string_literal: true

module GDK
  module Services
    # The Unfurl server's Python backend, behind unfurl-server (Unfurl), under
    # gunicorn as in production. Without UNFURL_SERVE_PATH it serves no local
    # project: every request names its own.
    class UnfurlBackend < Unfurl
      def name
        'unfurl-backend'
      end

      # One worker per request at a time; an export can outlast gunicorn's
      # default 30 seconds, so this waits as long as unfurl-server's proxy.
      def command
        "#{bin('python')} -m gunicorn -b localhost:#{BACKEND_PORT} -w 4 --timeout 120 unfurl.server.serve:app"
      end

      def env
        shared_env
      end

      def ready_message
        "Unfurl's Python backend is available at http://localhost:#{BACKEND_PORT}"
      end
    end
  end
end
