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
    # compensate for. An id is assigned at insert but visible at commit, so a
    # reader still holds back from the newest rows; see
    # OC::Projects::CloudmapRefreshWorker::LAG.
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
    # `group_archived` / `group_unarchived` / `group_deleted` /
    # `namespace_moved` / `group_included`
    #   A change to a namespace that alters every project beneath it without
    #   writing any of their rows. One row for the namespace, not one per
    #   project: project_path holds the *namespace's* full path and project
    #   is nil.
    #   visibility       the namespace's
    #   web_url          the namespace's
    #   namespace_id
    #   project_ids      every project beneath it, at any depth
    #   subgroup_ids     every group beneath it, at any depth; not project
    #                    namespaces. Absent for a user's namespace
    #
    # `namespace_moved` is a group rename or transfer, or a username change,
    # recorded after it commits, so project_path is the new path. It adds:
    #   namespace_type   Group or User
    #   old_path         the full path before the move
    #
    # `group_included` is a group marked to put every public project beneath
    # it in the cloudmap; see OC::GroupCustomAttribute.
    #
    # `group_deleted` lists what the hierarchy held before the destroy. Each of
    # those projects also leaves its own `project_deleted` row.
    #
    # The id lists are unbounded; a large hierarchy makes a large row.
    #
    # `metadata_changed`
    #   visibility       the project's
    #   web_url          the project's
    #   changed          what changed: project column names, or `topics` or
    #                    `unfurl_type`, neither of which is a column
    #   old_path         the full path before a rename or transfer; absent
    #                    otherwise
    #
    # Unlike every other kind, this one is also visible to a poll of
    # `projects.updated_at` -- except topics and unfurl_type -- but a push
    # moves that timestamp too, and these rows are only for what the
    # cloudmap's repository record reads.
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
        image_deleted: 6, mirror_synced: 7, group_archived: 8,
        group_unarchived: 9, namespace_moved: 10, group_deleted: 11,
        metadata_changed: 12, group_included: 13
      }

      belongs_to :organization, class_name: '::Organizations::Organization'
      # Nil once the project it describes is gone, which is the point of the
      # tombstone. project_path is what the cloudmap keys on regardless.
      belongs_to :project, class_name: '::Project', optional: true

      validates :occurred_at, :project_path, presence: true

      scope :after_cursor, ->(id) { where(arel_table[:id].gt(id)).order(:id) }
      scope :occurred_before, ->(time) { where(arel_table[:occurred_at].lt(time)) }

      # Where a consumer with no stored cursor starts: just before the first
      # row since `time`, or after the last row if there is none.
      def self.cursor_since(time)
        first = where(arel_table[:occurred_at].gteq(time)).minimum(:id)
        first ? first - 1 : maximum(:id).to_i
      end

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

        # Takes a snapshot from .namespace_snapshot rather than the namespace,
        # so a deletion can be read before the destroy and recorded after it.
        def record_for_namespace(snapshot, kind:)
          create!(
            kind: kind,
            organization_id: snapshot[:organization_id],
            project: nil,
            project_path: snapshot[:full_path],
            payload: snapshot[:payload].compact,
            occurred_at: Time.current
          )
        end

        def record_for_namespace_quietly(snapshot, kind:)
          quietly(kind, namespace_id: snapshot.dig(:payload, :namespace_id)) do
            record_for_namespace(snapshot, kind: kind)
          end
        end

        # One row per project, in one insert, for a change made to many
        # projects at once without saving any of them.
        def record_metadata_changes(projects, changed:)
          now = Time.current
          rows = projects.map do |project|
            {
              kind: kinds[:metadata_changed],
              organization_id: project.organization_id,
              project_id: project.id,
              project_path: project.full_path,
              payload: { visibility: project.visibility, web_url: project.web_url, changed: changed },
              occurred_at: now
            }
          end

          insert_all(rows) if rows.any?
        end

        # For callers recording a change that has already happened: a failure
        # here must not turn it into a failed one, so the feed loses a row
        # instead.
        def quietly(kind, **context)
          yield
        rescue ::StandardError => error
          ::Gitlab::AppLogger.warn(
            message: 'cloudmap event could not be recorded',
            kind: kind,
            **context,
            error_class: error.class.name,
            error_message: error.message)
          nil
        end

        # Plucked rather than left as relations, which would be evaluated
        # after a destroy and come back empty. Unlimited because the lists are
        # the payload, not the input to an IN clause.
        # rubocop:disable Database/AvoidUsingPluckWithoutLimit -- see above
        def namespace_snapshot(namespace, **extra)
          {
            full_path: namespace.full_path,
            organization_id: namespace.organization_id,
            payload: {
              visibility: namespace.visibility,
              web_url: namespace.web_url,
              namespace_id: namespace.id,
              project_ids: namespace.all_projects.order(:id).pluck(:id),
              subgroup_ids: (namespace.descendants.order(:id).pluck(:id) if namespace.group_namespace?)
            }.merge(extra)
          }
        end
        # rubocop:enable Database/AvoidUsingPluckWithoutLimit

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
