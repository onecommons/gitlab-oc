# frozen_string_literal: true

module OC
  module ContainerRegistry
    # OC Change -- tell the cloudmap feed about registry pushes and deletes.
    #
    # A module, not a class: this is the target of
    # `ContainerRegistry::Event.prepend_mod_with('ContainerRegistry::Event')`,
    # which is upstream's seam and which EE uses for the same purpose
    # (ee/app/models/ee/container_registry/event.rb). EE never loads here.
    #
    # Reached from POST /api/v4/container_registry_event/events, which the
    # registry calls only when its own config.yml carries a `notifications:`
    # block pointing at it -- the GDK's does not by default.
    module Event
      extend ::Gitlab::Utils::Override

      override :handle!
      def handle!
        super

        publish_cloudmap_event
      end

      private

      def publish_cloudmap_event
        action = cloudmap_action
        return unless action && project

        ::Gitlab::EventStore.publish(
          ::OC::ContainerRegistry::ImageChangedEvent.new(data: {
            project_id: project.id,
            action: action,
            repository: event.dig('target', 'repository'),
            tag: event.dig('target', 'tag'),
            digest: event.dig('target', 'digest')
          }.compact)
        )
      end

      # A `docker push` notifies once per blob as well as once per manifest,
      # and `supported?` lets all of them through -- so a push is only
      # interesting when it carries a tag. EE's equivalent omits that check and
      # emits an event per blob.
      #
      # A delete splits the other way: with a tag it is one reference going,
      # with a digest and no tag it is the image itself. Reporting both as one
      # kind would leave a consumer unable to tell a retagging from a removal.
      def cloudmap_action
        if action_push?
          ::OC::ContainerRegistry::ImageChangedEvent::PUSHED if target_tag?
        elsif action_delete?
          if target_tag?
            ::OC::ContainerRegistry::ImageChangedEvent::TAG_DELETED
          elsif target_digest?
            ::OC::ContainerRegistry::ImageChangedEvent::DELETED
          end
        end
      end
    end
  end
end
