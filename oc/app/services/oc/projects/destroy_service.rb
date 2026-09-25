# frozen_string_literal: true

module OC
  module Projects
    # OC Change -- leave a tombstone the cloudmap can find.
    #
    # Projects::ProjectDeletedEvent carries only ids, and a subscriber to it
    # runs once the row and its route are gone, so nothing downstream can
    # recover the path. Both are read here, before the destroy.
    #
    # Written straight to the table rather than published: a Sidekiq hop is a
    # loss channel, and this is the one record of the project that cannot be
    # rebuilt from anywhere afterwards.
    module DestroyService
      extend ::Gitlab::Utils::Override

      override :execute
      def execute
        # Everything the row needs, read while the project is still here.
        attributes = {
          full_path: project.full_path,
          organization_id: project.organization_id,
          visibility: project.visibility,
          web_url: project.web_url
        }

        result = super
        return result unless result

        record_deletion(attributes)

        result
      end

      private

      # Nothing here may turn a deletion that has already happened into a
      # failure, so the feed loses a row rather than the caller losing the
      # result.
      def record_deletion(attributes)
        ::OC::Projects::CloudmapEvent.record_deletion(
          attributes[:full_path], attributes[:organization_id],
          payload: { visibility: attributes[:visibility], web_url: attributes[:web_url] })
      rescue ::StandardError => error
        ::Gitlab::AppLogger.warn(
          message: 'cloudmap deletion event could not be recorded',
          ::Labkit::Fields::GL_PROJECT_PATH => attributes[:full_path],
          error_class: error.class.name,
          error_message: error.message)
      end
    end
  end
end
