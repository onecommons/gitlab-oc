# frozen_string_literal: true

require 'labkit/logging'

module Gitlab
  class JsonLogger < ::Labkit::Logging::JsonLogger
    class << self
      def file_name_noext
        raise NotImplementedError, "JsonLogger implementations must provide file_name_noext implementation"
      end

      def file_name
        file_name_noext + ".log"
      end

      def debug(message)
        build.debug(message)
      end

      def error(message)
        build.error(message)
      end

      def warn(message)
        build.warn(message)
      end

      def info(message)
        build.info(message)
      end

      def build
        Gitlab::SafeRequestStore[cache_key] ||=
          new(full_log_path, level: log_level).tap { |logger| rotate(logger) }
      end

      # OC Change: as Gitlab::Logger.rotation; Labkit's initialize takes no
      # rotation arguments, so reopen with them.
      def rotate(logger)
        rotation = Gitlab::Logger.rotation
        logger.reopen(nil, *rotation) if rotation.any?
      end

      def cache_key
        "logger:" + full_log_path.to_s
      end

      def full_log_path
        Rails.root.join("log", file_name)
      end
    end

    private

    # Override Labkit's default impl, which uses the default Ruby platform json module.
    def dump_json(data)
      Gitlab::Json.dump(data)
    end
  end
end
