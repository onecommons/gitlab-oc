# frozen_string_literal: true

module OC
  module ContainerRegistry
    # OC Change -- a tag appeared or went in the container registry.
    #
    # One event with an action rather than three classes: the payloads differ
    # only in which of tag and digest is present, and a consumer dispatches on
    # the action either way.
    class ImageChangedEvent < ::Gitlab::EventStore::Event
      PUSHED = 'pushed'
      TAG_DELETED = 'tag_deleted'
      DELETED = 'deleted'
      ACTIONS = [PUSHED, TAG_DELETED, DELETED].freeze

      def schema
        {
          'type' => 'object',
          'required' => %w[project_id action repository],
          'properties' => {
            'project_id' => { 'type' => 'integer' },
            'action' => { 'type' => 'string', 'enum' => ACTIONS },
            'repository' => { 'type' => 'string' },
            'tag' => { 'type' => 'string' },
            'digest' => { 'type' => 'string' }
          }
        }
      end
    end
  end
end
