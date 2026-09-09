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
    end

    override :avatar_url
    def avatar_url(**args)
      super || OC::Projects::UnfurlDefaultAvatar.url_for(self, only_path: args.fetch(:only_path, true))
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
    def record_unfurl_type!(type)
      custom_attributes.find_or_create_by(key: 'unfurl_type').update!(value: type)
    end
    # rubocop: enable CodeReuse/ActiveRecord

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
