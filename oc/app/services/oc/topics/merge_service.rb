# frozen_string_literal: true

module OC
  module Topics
    # OC Change -- the merge rewrites project_topics with update_all and
    # delete_all, which no project hook sees, so the projects it retopics are
    # recorded in the cloudmap feed here.
    module MergeService
      extend ::Gitlab::Utils::Override

      override :execute
      def execute
        # Read before super, which deletes the source topic's rows. Every one
        # of these projects changes: those without the target gain it, those
        # with both lose the source. Guarded because super validates the
        # topics, and has not yet.
        project_ids = source_topic.is_a?(::Projects::Topic) ? source_topic.project_ids : []

        super.tap do |result|
          next unless result.success?

          ::OC::Projects::CloudmapEvent.quietly(:metadata_changed, topic_id: target_topic.id) do
            ::OC::Projects::CloudmapEvent.record_metadata_changes(
              ::Project.id_in(project_ids).with_route, changed: %w[topics])
          end
        end
      end
    end
  end
end
