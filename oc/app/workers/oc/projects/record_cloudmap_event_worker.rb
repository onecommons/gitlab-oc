# frozen_string_literal: true

module OC
  module Projects
    # OC Change -- writes the cloudmap change feed for the events whose change
    # leaves nothing on `projects` for a poll to find.
    # See OC::Projects::CloudmapEvent, which documents the payloads.
    class RecordCloudmapEventWorker
      include ::Gitlab::EventStore::Subscriber

      feature_category :source_code_management
      urgency :low
      # Sticky rather than delayed: a pipeline that has only just finished may
      # not have reached a replica, and the event carries no project of its
      # own to fall back on.
      data_consistency :sticky
      defer_on_database_health_signal :gitlab_main_org, %i[oc_cloudmap_events], 1.minute

      # A replayed event writes a second row rather than colliding with the
      # first. That is deliberate: the feed is read with DISTINCT on
      # (project_path, kind), so a duplicate costs a row and nothing else,
      # where a unique key over a timestamp the event does not carry would
      # drop real changes to buy it.
      idempotent!

      IMAGE_KINDS = {
        ::OC::ContainerRegistry::ImageChangedEvent::PUSHED => :image_pushed,
        ::OC::ContainerRegistry::ImageChangedEvent::TAG_DELETED => :image_tag_deleted,
        ::OC::ContainerRegistry::ImageChangedEvent::DELETED => :image_deleted
      }.freeze

      def handle_event(event)
        case event
        when ::Projects::ProjectVisibilityChangedEvent then visibility_changed(event)
        when ::Ci::PipelineFinishedEvent then pipeline_finished(event)
        when ::Packages::PackageCreatedEvent then package_published(event)
        when ::OC::ContainerRegistry::ImageChangedEvent then image_changed(event)
        when ::OC::Repositories::MirrorSyncedEvent then mirror_synced(event)
        end
      end

      private

      # Recorded whatever the new level is. Which transitions matter is the
      # consumer's business: a cloudmap serving only public projects cares
      # about public <-> not-public, one that does not may care about all.
      #
      # The level comes from the event rather than the project, so a second
      # change landing before this job runs cannot make the row describe the
      # wrong one.
      def visibility_changed(event)
        with_project(event.data[:project_id]) do |project|
          record(project, :visibility_changed,
            visibility: ::Gitlab::VisibilityLevel.string_level(event.data[:visibility_level]),
            web_url: project.web_url)
        end
      end

      # Not filtered to successful pipelines, unlike this fork's other
      # subscribers to this event: the cloudmap records a run's status as a
      # property of the run, so a failure is a change it wants to hear about.
      #
      # The event names no project, so the pipeline is read for one. Its id
      # stays in the payload because the cloudmap still has to fetch the run
      # for the ref and finished_at it does not carry.
      def pipeline_finished(event)
        pipeline = ::Ci::Pipeline.find_by_id_and_partition(
          event.data[:pipeline_id], event.data[:partition_id])
        return unless pipeline

        record(pipeline.project, :pipeline_finished,
          pipeline_id: event.data[:pipeline_id],
          status: event.data[:status],
          source: event.data[:source],
          web_url: ::Gitlab::Routing.url_helpers.project_pipeline_url(pipeline.project, pipeline))
      end

      # `packages_public` rather than the project's visibility, because the
      # two are independent: a private project may serve packages anonymously,
      # and a public project may keep its registry to Reporters.
      def package_published(event)
        with_project(event.data[:project_id]) do |project|
          record(project, :package_published,
            package_id: event.data[:id],
            name: event.data[:name],
            version: event.data[:version],
            package_type: event.data[:package_type],
            packages_public: packages_public?(project),
            web_url: ::Gitlab::Routing.url_helpers.project_package_url(project, event.data[:id]))
        end
      end

      # Asked of the policy rather than recomputed, because the conditions do
      # not compose the way the names suggest.
      # `ProjectFeature#public_packages?` is `access_level == PUBLIC ||
      # project.public?`, which is true for a public project whose registry is
      # closed to Reporters -- it exists to decide whether a displayed URL
      # needs a token, not who may pull. The policy is the whole rule: the
      # feature's access level, the project's visibility, and (for a private
      # project opening its registry) the instance's
      # package_registry_allow_anyone_to_pull_option.
      def packages_public?(project)
        ::Users::Anonymous.can?(:read_package, project.packages_policy_subject)
      end

      # web_url is the registry page rather than the image's own: the event
      # names a registry path, and resolving it to a ContainerRepository row
      # to build a link would be a query for something a consumer indexes by
      # pull reference anyway.
      def image_changed(event)
        kind = IMAGE_KINDS[event.data[:action]]
        return unless kind

        with_project(event.data[:project_id]) do |project|
          record(project, kind,
            repository: event.data[:repository],
            image: pull_reference(event.data[:repository], event.data[:tag]),
            tag: event.data[:tag],
            digest: event.data[:digest],
            web_url: ::Gitlab::Routing.url_helpers.project_container_registry_index_url(project))
        end
      end

      # What `docker pull` would be given. Nil without a tag, which is the
      # manifest-delete case.
      def pull_reference(repository, tag)
        return if tag.blank?

        "#{::Gitlab.config.registry.host_port}/#{repository}:#{tag}"
      end

      def mirror_synced(event)
        with_project(event.data[:project_id]) do |project|
          record(project, :mirror_synced,
            ref: event.data[:ref],
            old_sha: event.data[:old_sha],
            new_sha: event.data[:new_sha],
            web_url: project.web_url)
        end
      end

      def with_project(project_id)
        project = ::Project.find_by_id(project_id)
        return unless project

        yield project
      end

      def record(project, kind, **payload)
        ::OC::Projects::CloudmapEvent.record_for(project, kind: kind,
          payload: { visibility: project.visibility }.merge(payload).compact)
      end
    end
  end
end
