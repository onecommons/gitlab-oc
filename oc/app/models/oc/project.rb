# frozen_string_literal: true

module OC
  module Project
    extend ActiveSupport::Concern
    extend ::Gitlab::Utils::Override

    prepended do
      # The table is in the CI database and projects is in main, so the
      # through-associations cannot join.
      has_many :upstream_project_subscriptions, class_name: 'OC::Ci::Subscriptions::Project',
        foreign_key: :downstream_project_id, inverse_of: :downstream_project
      has_many :upstream_projects, class_name: 'Project', through: :upstream_project_subscriptions,
        source: :upstream_project, disable_joins: true
      has_many :downstream_project_subscriptions, class_name: 'OC::Ci::Subscriptions::Project',
        foreign_key: :upstream_project_id, inverse_of: :upstream_project
      has_many :downstream_projects, class_name: 'Project', through: :downstream_project_subscriptions,
        source: :downstream_project, disable_joins: true

      # rubocop: disable CodeReuse/ActiveRecord -- custom attributes are the project's own key/value store
      scope :with_unfurl_type, ->(types) do
        joins(:custom_attributes).where(project_custom_attributes: { key: 'unfurl_type', value: types })
      end
      # rubocop: enable CodeReuse/ActiveRecord

      after_update -> { record_cloudmap_metadata_change(cloudmap_metadata_changes, old_path: cloudmap_old_path) },
        if: -> { cloudmap_metadata_changes.any? }
    end

    # The columns the cloudmap's repository record reads from the GitLab host
    # (unfurl/cloudmap/gitlab.py). Timestamps are left out on purpose: a push
    # touches last_activity_at and last_repository_updated_at, and with them
    # updated_at, and a push is not a metadata change.
    #
    # Topics are not a column; OC::Projects::UpdateService and
    # OC::Topics::MergeService record those.
    CLOUDMAP_METADATA_ATTRIBUTES = %w[
      name path namespace_id description visibility_level avatar archived marked_for_deletion_at
    ].freeze

    # After commit, so a reader of the feed cannot see the row before the
    # change it describes, and a rolled-back change leaves none.
    def record_cloudmap_metadata_change(changed, old_path: nil)
      run_after_commit_or_now do
        ::OC::Projects::CloudmapEvent.quietly(:metadata_changed, project_id: id) do
          ::OC::Projects::CloudmapEvent.record_for(self, kind: :metadata_changed,
            payload: { visibility: visibility, web_url: web_url, changed: changed, old_path: old_path }.compact)
        end
      end
    end

    # What the repository says the project is, without recording it.
    def computed_unfurl_type
      if repository.ensemble_template_yaml.present?
        OC::UNFURL_BLUEPRINT
      elsif repository.unfurl_yaml.present?
        OC::UNFURL_DASHBOARD
      else
        OC::REGULAR_PROJECT
      end
    end

    # What the project is, for a request that must not write. Only the signup
    # path records a type at creation; a project that arrives any other way --
    # pushed into existence, imported, forked, seeded -- has none until
    # ProjectCacheWorker catches up, and a dashboard without one renders as an
    # ordinary GitLab project.
    def unfurl_type_without_recording
      recorded_unfurl_type.presence || (computed_unfurl_type if repository_exists?)
    end

    # recalculate the project type custom attribute
    # rubocop: disable CodeReuse/ActiveRecord -- custom attributes are the project's own key/value store
    def refresh_unfurl_type!
      record_unfurl_type!(computed_unfurl_type)
    end

    # A project whose files are not there yet -- a template import runs in a
    # worker -- has to be told what it is.
    #
    # Recorded in the cloudmap feed when the type changes, since that can make
    # a project newly qualify for a refresh.
    def record_unfurl_type!(type)
      attribute = custom_attributes.find_or_create_by(key: 'unfurl_type')
      attribute.update!(value: type)
      return unless attribute.previously_new_record? || attribute.saved_change_to_value?

      record_cloudmap_metadata_change(%w[unfurl_type])
    end
    # rubocop: enable CodeReuse/ActiveRecord

    def cloudmap_metadata_changes
      saved_changes.keys & CLOUDMAP_METADATA_ATTRIBUTES
    end

    # The full path before a rename or transfer, read while the change is
    # still in saved_changes. Not upstream's full_path_before_last_save, which
    # joins the old path to the *current* namespace and so is wrong for a
    # transfer.
    def cloudmap_old_path
      return unless saved_change_to_path? || saved_change_to_namespace_id?

      old_namespace = if saved_change_to_namespace_id?
                        ::Namespace.find_by_id(namespace_id_before_last_save)
                      else
                        namespace
                      end

      [old_namespace&.full_path, path_before_last_save].compact.join('/')
    end

    def unfurl_blueprint?
      unfurl_type == OC::UNFURL_BLUEPRINT
    end

    # What the classifier last stored, without classifying. unfurl_type falls
    # back to refresh_unfurl_type!, which writes, so anything rendering a GET
    # reads this instead.
    # rubocop: disable CodeReuse/ActiveRecord -- custom attributes are the project's own key/value store
    def recorded_unfurl_type
      custom_attributes.find_by(key: 'unfurl_type')&.value
    end
    # rubocop: enable CodeReuse/ActiveRecord

    def unfurl_dashboard?
      unfurl_type == OC::UNFURL_DASHBOARD
    end

    def regular_project?
      unfurl_type == OC::REGULAR_PROJECT
    end

    # OC Change -- how many times this blueprint has been deployed. Recorded as
    # deployments finish rather than counted from pipeline variables, which are
    # not indexed by value; see OC::Environments::BlueprintDeployment.
    def blueprint_deployment_count
      ::OC::Environments::BlueprintDeployment.for_blueprint(self).count
    end

    # OC Change -- pull mirroring
    # A mirror keeps its import credentials, because unsafe_import_url
    # rebuilds them from import_data and a mirror goes on fetching long after
    # the import has finished.
    override :remove_import_data
    def remove_import_data
      super unless mirror_requested?
    end

    # The import records the request to mirror; there is no `mirror` column in
    # this edition, because upstream's is gated on an EE feature.
    #
    # Whatever the project's type: a blueprint or dashboard can be mirrored
    # too. A project made from an Unfurl template cannot be, which 15.11
    # ensured by requiring a Regular type; here templates are built-in
    # archives with no URL to fetch from, and only the GitHub import records
    # the request.
    def mirror?
      import? && mirror_requested?
    end

    def mirror_enabled?
      mirror? && import_data&.data&.dig('mirror_enabled')
    end

    def mirror_requested?
      import_data&.data&.dig('is_mirror').present?
    end

    # Work items sync (issues/MRs mirrored into the gitlab-work-items branch)
    # defaults to on for unfurl projects and off for everything else. An
    # explicit choice made on the settings page or through the API always wins,
    # so an unfurl project can turn it off.
    def work_items_sync_enabled?
      case work_items_sync_setting
      when 'enabled' then true
      when 'disabled' then false
      else work_items_sync_on_by_default?
      end
    end

    def work_items_sync_on_by_default?
      unfurl_blueprint? || unfurl_dashboard?
    end

    def work_items_sync_opted_in?
      work_items_sync_setting == 'enabled'
    end

    # Turned off deliberately, as opposed to merely never turned on. The
    # importer needs the difference: it enables sync on a project that has not
    # made a choice, and must leave one that has alone.
    def work_items_sync_opted_out?
      work_items_sync_setting == 'disabled'
    end

    # How far an import may go in deciding that a user on another instance is a
    # user here is declared per relationship in the branch's sync.yml
    # (`user_mapping`), not per project. It was a custom attribute here first,
    # settable only from a console, which made a per-instance question out of
    # something that is really per-peer: an instance may know one peer's people
    # and none of another's. See OC::WorkItems::SyncFile.

    def enable_work_items_sync!(enabled)
      write_work_items_sync_setting!('work_items_sync', enabled ? 'enabled' : 'disabled')
    end

    # Confidential issues and internal notes are kept out of the branch by
    # default on every project, whatever its visibility. Anything committed
    # stays readable in the branch's history even after the file is deleted, so
    # the safe default is not to write it at all.
    #
    # A private project can opt in: everyone who can read its repository is
    # already a Reporter or above and can see confidential issues anyway.
    # Public and internal projects can never sync them.
    def sync_confidential_work_items?
      private? && work_items_sync_confidential_included?
    end

    # rubocop: disable CodeReuse/ActiveRecord -- custom attributes are the project's own key/value store
    def work_items_sync_confidential_included?
      custom_attributes.find_by(key: 'work_items_sync_confidential')&.value == 'include'
    end
    # rubocop: enable CodeReuse/ActiveRecord

    def include_work_items_sync_confidential!(included)
      write_work_items_sync_setting!('work_items_sync_confidential', included ? 'include' : 'exclude')
    end

    SYNCED_AT_KEY = 'work_items_synced_at'
    SWEPT_AT_KEY = 'work_items_swept_at'

    # When a full pass last scanned this project, and when one last scanned it
    # *unfiltered*. Both exist so the two cron jobs can skip a project without
    # touching Gitaly: an instance with far more dead projects than live ones
    # would otherwise spend every night reading a branch that cannot have
    # changed, and every week re-serializing records nobody has touched in a
    # year.
    #
    # The commit trailer remains the authority on how far a pass got --
    # these are only ever read to decide whether to do the work at all, so
    # being stale in the eager direction costs a wasted pass and nothing more.
    def work_items_synced_at
      read_work_items_timestamp(SYNCED_AT_KEY)
    end

    def work_items_swept_at
      read_work_items_timestamp(SWEPT_AT_KEY)
    end

    # `unfiltered` records that the pass looked at everything, which is what
    # SweepWorker is asking for -- whoever actually asked for the pass.
    def record_work_items_sync!(scanned_at, unfiltered:)
      write_work_items_timestamp!(SYNCED_AT_KEY, scanned_at)
      write_work_items_timestamp!(SWEPT_AT_KEY, scanned_at) if unfiltered
    end

    private

    # rubocop: disable CodeReuse/ActiveRecord -- custom attributes are the project's own key/value store
    def read_work_items_timestamp(key)
      raw = custom_attributes.find_by(key: key)&.value
      return if raw.blank?

      Time.zone.parse(raw)
    rescue ArgumentError
      nil
    end

    # Deliberately does not touch the project, unlike the settings writer
    # below: bumping updated_at here would make every project look changed to
    # the very check these exist to satisfy.
    def write_work_items_timestamp!(key, time)
      custom_attributes.find_or_create_by(key: key).update!(value: time.utc.iso8601)
    end
    # rubocop: enable CodeReuse/ActiveRecord

    # rubocop: disable CodeReuse/ActiveRecord -- custom attributes are the project's own key/value store
    def work_items_sync_setting
      custom_attributes.find_by(key: 'work_items_sync')&.value
    end

    # Touch the project as well: custom attribute rows don't bump the project's
    # updated_at, so without this the nightly reconcile has no staleness signal
    # that a setting changed and the branch could keep stale content if the
    # full sync enqueued alongside this is ever lost.
    def write_work_items_sync_setting!(key, value)
      custom_attributes.find_or_create_by(key: key).update!(value: value)
      touch
    end
    # rubocop: enable CodeReuse/ActiveRecord

    # rubocop: disable CodeReuse/ActiveRecord -- custom attributes are the project's own key/value store
    def unfurl_type
      type = custom_attributes.find_by(key: 'unfurl_type')

      # force re-cache if attribute is missing
      if type.nil?
        refresh_unfurl_type!
        type = custom_attributes.find_by(key: 'unfurl_type')
      end

      type&.value
    end
    # rubocop: enable CodeReuse/ActiveRecord
  end
end
