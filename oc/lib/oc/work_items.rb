# frozen_string_literal: true

module OC
  module WorkItems
    SYNC_BRANCH = 'gitlab-work-items'

    # How long a sync waits before it runs, so that a burst of edits to one
    # item becomes one commit instead of five. Ten seconds is the right answer
    # for people editing issues, and the wrong one for a test that has to sit
    # through every occurrence of it: the end-to-end suite spends more time
    # waiting out this delay than doing anything else.
    #
    # So it can be shortened by the environment. Deliberately an environment
    # variable rather than a setting: it belongs to the process, not to the
    # installation, so nobody can slow another instance's syncs down by
    # editing something, and a test run needs no configuration file changed to
    # use it.
    #
    # Read per call rather than frozen into a constant, and anything that is
    # not a number of seconds at least zero is ignored in favour of the
    # default -- a mistyped value should be slow, not instant.
    DEFAULT_SYNC_DELAY = 10.seconds
    SYNC_DELAY_VAR = 'OC_WORK_ITEMS_SYNC_DELAY'

    def self.sync_delay
      configured = ::ENV[SYNC_DELAY_VAR]
      return DEFAULT_SYNC_DELAY if configured.blank?

      seconds = Float(configured, exception: false)
      return DEFAULT_SYNC_DELAY if seconds.nil? || seconds < 0

      seconds.seconds
    end

    # Pipelines for the sync branch are suppressed in
    # OC::Git::BaseHooksService#create_pipelines (Gitaly's UserCommitFiles
    # cannot carry `ci.skip` push options in this version). The message must
    # never contain `#N`/`!N` reference tokens, which would create
    # cross-reference system notes on every sync.
    COMMIT_MESSAGE = 'Sync work items'

    # Git trailers on every sync commit. None of them is sanitised: a reference
    # token in any value is inert, because OC::Git::BranchHooksService opts the
    # sync branch out of commit-message processing altogether.
    #
    # * Version -- which build wrote the commit. Exactly what the help page
    #   shows as "Current Version" (`oc/app/views/help/index.html.haml`).
    # * Instance -- which Unfurl Cloud installation wrote it. A branch that has
    #   been mirrored, forked or restored elsewhere can be traced back.
    # * Export schema -- upstream's import/export version for the records in
    #   this commit. Lives here rather than in the files so an upstream bump
    #   does not rewrite the whole branch; `git log -1 -- <uuid>/issues/42.yml`
    #   gives the exact version that produced any one file.
    # * Synced through -- how far a full pass scanned. Read by ReconcileWorker
    #   to compute the next window; see FullSyncWorker for why the window
    #   travels as a job argument rather than being re-read there.
    VERSION_TRAILER = 'Unfurl-Cloud-Version'
    INSTANCE_TRAILER = 'Unfurl-Cloud-Instance'
    EXPORT_SCHEMA_TRAILER = 'Work-Items-Export-Schema'
    SYNCED_THROUGH_TRAILER = 'Work-Items-Synced-Through'

    # synced_through: a Time when a full pass wrote this commit, nil for an
    # incremental one -- which syncs a single record and has scanned nothing,
    # so it must never advance the watermark. Incremental commits carry the
    # existing value forward instead (see SyncService#commit!), keeping the
    # watermark on HEAD wherever the last commit came from.
    def self.commit_message(synced_through: nil)
      trailers = {
        VERSION_TRAILER => ::Gitlab.revision.presence,
        INSTANCE_TRAILER => instance_id,
        EXPORT_SCHEMA_TRAILER => ::Gitlab::ImportExport::VERSION,
        SYNCED_THROUGH_TRAILER => synced_through&.utc&.iso8601
      }.compact

      "#{COMMIT_MESSAGE}\n\n#{trailers.map { |key, value| "#{key}: #{value}\n" }.join}"
    end

    # nil on an instance that has neither -- possible in test environments,
    # where an empty trailer would be worse than no trailer.
    def self.instance_id
      [::Gitlab::CurrentSettings.uuid, ::Gitlab.config.gitlab.url].filter_map(&:presence).join(' ').presence
    end

    # Raised rather than writing a path whose first segment is empty.
    MissingInstanceUuidError = Class.new(StandardError)

    # The directory on the branch holding this instance's files. Every file we
    # write lives under it, so two instances sharing a branch cannot collide at
    # issues/42.yml and whoever resolves a merge conflict can tell whose file
    # is whose.
    #
    # The bare uuid -- not INSTANCE_TRAILER's value, which is the uuid and the
    # url joined by a space.
    #
    # Computed per call and never memoized into a constant. Constants are built
    # at class load, when CurrentSettings can still be the uuid-less fake
    # (Gitlab::FakeApplicationSettings is built from ApplicationSetting.defaults,
    # which has no uuid -- only the before_validation ensure_uuid! sets one), and
    # a constant would freeze that. Unlike instance_id this cannot degrade to
    # nil: a blank first segment would put the whole branch at the wrong paths.
    def self.instance_directory
      uuid = ::Gitlab::CurrentSettings.uuid.presence
      raise MissingInstanceUuidError, 'instance uuid is blank; refusing to write work item files' unless uuid

      uuid
    end

    SYNCED_THROUGH_PATTERN = /^#{Regexp.escape(SYNCED_THROUGH_TRAILER)}: (.+)$/

    def self.synced_through(commit_message)
      raw = commit_message.to_s[SYNCED_THROUGH_PATTERN, 1]
      return if raw.blank?

      Time.zone.parse(raw)
    rescue ArgumentError
      nil
    end

    # MRs from/to the sync branch itself are excluded: their serialized
    # branch shas change with every sync commit, so syncing them would
    # defeat the byte-identical convergence check and loop forever.
    def self.syncable?(issuable)
      case issuable
      when ::MergeRequest
        issuable.source_branch != SYNC_BRANCH && issuable.target_branch != SYNC_BRANCH
      when ::Issue
        true
      else
        false
      end
    end

    # Award emoji sit either on the issuable itself or on one of its notes;
    # either way the file holding that note is what needs re-serializing.
    # AwardEmoji has no touch callback and fires no issuable hooks, so
    # without this the reaction would drift invisibly (the reconcile cron's
    # updated_at staleness check cannot see it either).
    def self.enqueue_award_sync(awardable, user = nil)
      if awardable.is_a?(::Note)
        enqueue_note_sync(awardable, user)
      else
        enqueue_sync(awardable, user)
      end
    end

    # Single dispatch point for every note trigger. A note on a commit belongs
    # to commit_notes/<sha>.yml, everything else to its noteable's file.
    #
    # The commit branch deliberately reads only in-memory columns
    # (noteable_type, commit_id, project_id): `note.noteable` for a commit note
    # is a Gitaly lookup that returns nil once the commit is unreachable, and
    # the note still has to be synced either way.
    def self.enqueue_note_sync(note, user = nil)
      if note.for_commit?
        enqueue_commit_notes_sync(note.project, note.commit_id, user)
      else
        enqueue_sync(note.noteable, user)
      end
    end

    def self.enqueue_commit_notes_sync(project, commit_id, user = nil)
      return if sync_suppressed?
      return unless project&.work_items_sync_enabled?
      return if commit_id.blank?

      CommitNotesSyncWorker.perform_in(sync_delay, project.id, commit_id, user&.id)
    end

    SUPPRESSED_KEY = :oc_work_items_sync_suppressed

    # Runs a block with the sync triggers turned off.
    #
    # For the importer, which applies an update by rebuilding: it destroys the
    # replica and its notes and builds them again, and every one of those
    # destroys and creates fires a trigger that would queue a sync for a file
    # the importer is about to write itself. Suppressing them removes a burst
    # of jobs whose only outcome is to re-derive what we already know.
    #
    # A thread-local is the only channel available -- the triggers are prepended
    # into upstream services several call levels down, with no argument to
    # thread a flag through -- and it is sufficient here because the enqueues
    # being suppressed are raised synchronously, on this thread, by the
    # importer's own work. The triggers call enqueue_sync inline rather than
    # from an after_commit hook, so none of them escape to another thread.
    #
    # This is an optimization and NOT a safety mechanism. Nothing may depend on
    # it for correctness: a worker in another process cannot see this flag, and
    # is not meant to. What stops a concurrent worker doing damage is
    # SyncService#remove refusing to delete a file whose iid still resolves,
    # which holds whatever thread or server it runs on.
    def self.suppress_sync
      previous = ::Thread.current[SUPPRESSED_KEY]
      ::Thread.current[SUPPRESSED_KEY] = true
      yield
    ensure
      # Restored rather than cleared, so a nested call cannot switch the
      # triggers back on for the outer one, and so a raise inside the block
      # cannot leave this thread suppressed for whatever Sidekiq runs on it
      # next.
      ::Thread.current[SUPPRESSED_KEY] = previous
    end

    def self.sync_suppressed?
      ::Thread.current[SUPPRESSED_KEY] == true
    end

    # Confidential content that was already committed cannot be un-published by
    # deleting the files -- it stays readable in the branch history. When a
    # project stops syncing it (turning public, or switching the option off),
    # the branch is rebuilt from scratch instead.
    #
    # Callers capture `sync_confidential_work_items?` before their change and
    # pass it here afterwards; nothing happens unless it actually went from
    # true to false.
    def self.purge_confidential_history(project, was_syncing_confidential)
      return unless was_syncing_confidential
      return if project.sync_confidential_work_items?

      FullSyncWorker.perform_async(project.id, true)
    end

    # The labels and milestones a work item in this project can reference:
    # its own, plus every ancestor group's. `project.labels` is project-scoped
    # only (it is a ProjectLabel association), which is why this is a query
    # rather than an association call.
    #
    # ReconcileWorker watches these same two scopes for staleness. They have
    # to stay in agreement: a scope that syncs more than the reconcile watches
    # is a scope whose edits are never noticed.
    #
    # rubocop: disable CodeReuse/ActiveRecord -- the query belongs to the sync and has no finder
    def self.labels_for(project)
      ::Label.where(project_id: project.id).or(::Label.where(group_id: ancestor_group_ids(project)))
    end

    def self.milestones_for(project)
      ::Milestone.where(project_id: project.id).or(::Milestone.where(group_id: ancestor_group_ids(project)))
    end
    # rubocop: enable CodeReuse/ActiveRecord

    def self.ancestor_group_ids(project)
      project.group ? project.group.self_and_ancestor_ids : []
    end

    # Every project that might be syncing, as custom attribute rows. A project
    # can match twice (an unfurl project that also opted in explicitly), so
    # callers dedupe by project_id. Shared by ReconcileWorker and SweepWorker
    # so the two cron jobs cannot cover different sets of projects.
    #
    # rubocop: disable CodeReuse/ActiveRecord -- the query belongs to the sync and has no finder
    def self.sync_candidates
      ::ProjectCustomAttribute
        .where(key: 'unfurl_type', value: [OC::UNFURL_BLUEPRINT, OC::UNFURL_DASHBOARD])
        .or(::ProjectCustomAttribute.where(key: 'work_items_sync', value: 'enabled'))
    end
    # rubocop: enable CodeReuse/ActiveRecord

    # Central enqueue guard used by all trigger prepends. `issuable` may
    # already be destroyed (deletion triggers) -- only in-memory attributes
    # are read.
    def self.enqueue_sync(issuable, user = nil)
      return if sync_suppressed?
      return unless syncable?(issuable)

      project = issuable.project
      return unless project&.work_items_sync_enabled?

      type = issuable.is_a?(::MergeRequest) ? 'MergeRequest' : 'Issue'
      OC::WorkItems::SyncWorker.perform_in(
        sync_delay, project.id, type, issuable.id, issuable.iid, user&.id)
    end
  end
end
