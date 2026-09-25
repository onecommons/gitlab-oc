# frozen_string_literal: true

module OC
  module Projects
    # OC Change -- the project changes the cloudmap sync cannot find by
    # polling.
    #
    # Most of what it needs is reachable through
    # `GET /projects?updated_after=`, because anything that saves the project
    # row moves `projects.updated_at`. Two things do not. A deleted project
    # leaves no row to poll and no timestamp to compare; and a project that
    # turns private stops matching the query at all, which a poll cannot tell
    # apart from nothing having happened.
    #
    # Both land here instead, keyed by an autoincrement id the sync reads as a
    # cursor -- so unlike the timestamp poll there is no throttle to
    # compensate for and no overlap window to re-scan.
    #
    # Not OC::Event, and the table is not oc_events: upstream's activity-feed
    # model ends with `Event.prepend_mod_with('Event')`, so that constant is
    # its extension slot and a class defined there is prepended onto it at
    # boot, which fails with a TypeError far from the cause.
    #
    # ## The payloads
    #
    # A consumer lives in another repository, so these shapes are a contract
    # rather than an implementation detail. Each kind's payload in full:
    #
    # `visibility_changed`
    #   visibility       the project's new level: public, internal or private
    #   web_url          the project's
    #
    # `project_deleted`
    #   visibility       what it had when it went, so a consumer knows whether
    #                    it ever held a record to remove
    #   web_url          the project's, as it was
    #
    # `pipeline_finished`
    #   visibility       the project's
    #   web_url          the run's
    #   pipeline_id      so the run can be fetched for the ref and finished_at
    #                    this does not carry
    #   status           any terminal status, not only success
    #   source           what triggered it
    #
    # `package_published`
    #   visibility       the *project's*, which does not decide the next line
    #   web_url          the package's
    #   packages_public  whether an anonymous request may pull it. Asked of
    #                    the policy, not derived: measured on 19.3, a public
    #                    project serves packages anonymously unless its
    #                    registry is DISABLED -- setting it to PRIVATE does
    #                    not close it -- while a private project does so only
    #                    with a PUBLIC registry *and* the instance's
    #                    package_registry_allow_anyone_to_pull_option.
    #                    ProjectFeature#public_packages? answers this wrongly
    #                    in both of those corners; it exists to decide whether
    #                    a displayed URL needs a token
    #   package_id       the package row's id, not this row's
    #   name, version, package_type
    #
    # `image_pushed` / `image_tag_deleted` / `image_deleted`
    #   visibility       the project's
    #   web_url          the project's container registry page, which needs no
    #                    lookup; the registry event names a path, not a
    #                    ContainerRepository row
    #   repository       the registry path, as the registry reported it
    #   image            the pull reference, <host_port>/<repository>:<tag>.
    #                    Absent on a manifest delete, which has no tag
    #   tag              absent on a manifest delete
    #   digest           absent on some pushes
    #
    # A push carrying no tag is not recorded at all: one `docker push` notifies
    # once per blob, and only the manifest notification carries the tag.
    #
    # `mirror_synced`
    #   visibility       the project's
    #   web_url          the project's
    #   ref              the ref that moved, short name
    #   old_sha          nil when the ref did not exist here before
    #   new_sha          where it is now
    #
    # One ref only, and no deletions: force mode removes local-only branches
    # without reporting them.
    #
    # Keys read back as strings -- jsonb round-trips through JSON -- and a key
    # whose value was nil is dropped rather than stored as null.
    class CloudmapEvent < ApplicationRecord
      include DeleteWithLimit

      self.table_name = 'oc_cloudmap_events'

      # Numbers are a wire format once a consumer stores them: append, never
      # renumber or reuse.
      enum :kind, {
        visibility_changed: 0, project_deleted: 1, pipeline_finished: 2,
        package_published: 3, image_pushed: 4, image_tag_deleted: 5,
        image_deleted: 6, mirror_synced: 7
      }

      belongs_to :organization, class_name: '::Organizations::Organization'
      # Nil once the project it describes is gone, which is the point of the
      # tombstone. project_path is what the cloudmap keys on regardless.
      belongs_to :project, class_name: '::Project', optional: true

      validates :occurred_at, :project_path, presence: true

      scope :after_cursor, ->(id) { where(arel_table[:id].gt(id)).order(:id) }
      scope :occurred_before, ->(time) { where(arel_table[:occurred_at].lt(time)) }

      class << self
        # Records a change to a project that still exists.
        def record_for(project, kind:, payload: {})
          create!(
            kind: kind,
            organization_id: project.organization_id,
            project: project,
            project_path: project.full_path,
            payload: payload,
            occurred_at: Time.current
          )
        end

        # Records a project that has just been destroyed. Takes the path and
        # the organization rather than the record, because by the time a
        # caller knows the destroy succeeded the row and its route are gone.
        def record_deletion(project_path, organization_id, payload: {})
          create!(
            kind: :project_deleted,
            organization_id: organization_id,
            project: nil,
            project_path: project_path,
            payload: payload.compact,
            occurred_at: Time.current
          )
        end
      end
    end
  end
end
