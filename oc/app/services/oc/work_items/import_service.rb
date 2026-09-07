# frozen_string_literal: true

module OC
  module WorkItems
    # Builds one local replica from one document on a peer's branch.
    #
    # Uses the import/export machinery rather than the ordinary services,
    # because the documents on the branch *are* import/export documents -- they
    # were produced by AttributesFinder plus record.to_json, and
    # RelationFactory is the exact inverse. Three things follow from that which
    # are hard to get any other way:
    #
    # * the iid is preserved. RelationFactory sets `importing = true`
    #   (base/relation_factory.rb:181), and Issue declares
    #   `has_internal_id :iid, track_if: -> { !importing? }`, so a supplied iid
    #   is kept rather than reallocated.
    # * policies are bypassed, so the read-only policy needs no exception for
    #   us. It only has to stop people.
    # * ObjectBuilder find-or-creates the labels and milestones a document
    #   refers to, across the project's ancestor groups.
    class ImportService
      # Keys this fork adds to a document that no model has an attribute for.
      # Stripped rather than ignored: RelationFactory assigns what it is given.
      #
      # transferred_from is on a document whose owner took it from somewhere
      # else, and names the path it used to live at. It is read before the
      # strip, by the instance that path belongs to -- see the demote path.
      ADDED_KEYS = %w[_schema web_url uploads transferred_from].freeze

      # A merge request is only buildable if these resolve in the local
      # repository. They are refs, not content: a diff whose base is a commit
      # this instance has never seen cannot be rendered, and MergeRequestDiff
      # will try to recreate refs it cannot.
      DIFF_SHA_KEYS = %w[base_commit_sha start_commit_sha head_commit_sha].freeze

      RELATION_SYM = { issue: :issues, merge_request: :merge_requests }.freeze

      # identities: the peer's whole ids.yml, not just its users. The projects
      # section is what turns a source project id into the path its URLs are
      # built from, which is the only exact way to work out the peer's base URL
      # -- see source_origin.
      def initialize(
        project, source_instance_uuid:, identities: {}, trust: :none, default_user: nil)
        @project = project
        @source_instance_uuid = source_instance_uuid
        identities = (identities || {}).stringify_keys
        @identities = (identities['users'] || {}).transform_keys(&:to_i)
        @source_paths = (identities['projects'] || {}).transform_keys(&:to_i)
        @members_mapper = ImportMembersMapper.new(
          identities: @identities, trust: trust, default_user: default_user, ghost_user: ghost_user)
      end

      # action:   an ImportReconciler::Action of kind :import or :rebuild
      # document: the parsed YAML at action.path
      #
      # Source iids the last import referred to but could not resolve, because
      # the referenced item is deferred or has not been seen yet. A run
      # collects these and rebuilds the referring item once the referenced one
      # lands -- nothing in the source file will change to prompt it.
      attr_reader :unresolved_references

      # Returns the replica row, or nil when the project has opted out.
      def import(action, document)
        @unresolved_references = []

        # A project that deliberately turned sync off is not opted back into it
        # by someone else pushing a branch at it.
        return if @project.work_items_sync_opted_out?

        # A reference file is a pointer, not an item -- no title, no author,
        # nothing to build a record from. It turns up here when a peer holds
        # replicas of a third instance's work and pushes its branch onward.
        #
        # Skipping it does not skip that third instance: their actual
        # documents travel in the same branch under their own directory, and
        # are imported first-hand from there, with their own ids.yml and their
        # own web_url. Only the pointer is passed over. What it points at
        # matters for rewriting references, which reads the file at the time
        # rather than needing a record here.
        if RecordSerializer.reference?(document['_schema'])
          return withhold(action, document, :skipped, 'reference to an item on another instance')
        end

        # Confidential items are never replicated, whatever the source
        # instance chose to publish. A row is still recorded, so the nightly
        # does not re-read and re-parse the same blob every night to reach the
        # same conclusion -- and if the item only became confidential after we
        # imported it, the replica we already built is destroyed.
        return withhold(action, document, :skipped, 'confidential') if document['confidential']

        # A document that says it used to be ours, which is the last step of a
        # transfer and the only part of one that arrives through the files.
        completion = transfer_completion(action, document)
        return completion if completion

        # Before anything is built: the document may describe an item this
        # project already has.
        native = already_here(action, document)
        return match(action, document, native) if native

        reason = deferral_reason(action, document)
        return withhold(action, document, :deferred, reason) if reason

        replicate(action, document)
      end

      # Records that this document cannot be built, so the run stops trying.
      #
      # Without a state of its own, one bad file is re-attempted on every run
      # for ever -- and because the exception escapes, every file after it in
      # the run goes unprocessed too, deterministically, through all retries.
      # One document nobody can build should cost one document.
      #
      # An existing replica is deliberately left standing. If a *rebuild*
      # failed, the copy built from the previous version of the file is still
      # a truer thing to show than nothing at all.
      def record_failure(action, web_url, message)
        replica = action.replica || OC::WorkItems::ReplicatedWorkItem.new(
          project: @project,
          source_instance_uuid: @source_instance_uuid,
          source_path: action.path)

        replica.assign_attributes(
          source_kind: action.source_kind,
          source_iid: action.source_iid,
          source_blob_oid: action.oid,
          state: :errored,
          reason: message.to_s.truncate(255))
        replica.source_web_url ||= web_url
        replica.save!

        replica
      end

      private

      # pinned_iid: the number the record must have, overriding what the
      # document asks for. Only a demote passes one -- see #demote.
      def replicate(action, document, pinned_iid: nil)
        web_url = document['web_url']
        # Read before RelationFactory rewrites every project reference to this
        # project's id; afterwards the source's own id is gone.
        source_project_id = document['project_id'] || document['target_project_id']
        label_groups = source_label_groups(document)
        attributes = prepare(document, web_url)

        # Resolve the ghost user before the transaction opens. Users::Internal.ghost
        # creates it on first use under an exclusive lease, which may not be
        # taken inside a transaction; and created inside one that later rolls
        # back it goes away again while the memoized id does not, so the next
        # document fails on "Author can't be blank".
        @members_mapper.default_user_id
        ghost_user

        # Suppressed because a rebuild's destroy and the new record's create
        # would each fire a sync trigger, queueing work for a file this run
        # writes itself. Not a safety mechanism -- see
        # OC::WorkItems.suppress_sync.
        replica = OC::WorkItems.suppress_sync do
          # One transaction for the record and its row. The row is the
          # authoritative answer to "have I imported this file?", so a record
          # that exists without one would be imported a second time by the
          # next run, and a row without a record would hide a file that never
          # arrived.
          ::ApplicationRecord.transaction do
            next unless unchanged?(action)

            # Read before the destroy, which is what frees it.
            iid = pinned_iid || reusable_iid(action)

            release_record!(action.replica)

            # Only when nothing above chose one. After the destroy, because
            # that is what frees the number this copy was already using -- and
            # a matched row releases without destroying, so its number stays
            # taken, which is right: the item still here under it is ours.
            iid = action.source_iid if iid.nil? && iid_free?(action)

            record = build(action, iid ? attributes.merge('iid' => iid) : attributes.except('iid'))
            allocate_iid(record) unless iid
            record.save!
            track_iid!(record) if iid

            upsert_replica(action, record, web_url, state: :imported,
              identities: identity_map(record, source_project_id, label_groups),
              unresolved: @unresolved_references)
          end
        end

        return unless replica

        start_syncing
        replica
      end

      # Whether the row still says what it said when this action was planned.
      #
      # A plan is taken from rows and executed later, and until transfers
      # existed that was harmless: every action was convergent, so acting on a
      # stale one cost a rebuild and no more. Promotion breaks that. A row that
      # was a copy when the plan was made can be an item this instance owns by
      # the time the action runs -- and both a rebuild and a delete begin by
      # destroying the record. There are no leases here by design, and Sidekiq
      # deduplication stops a second job being enqueued, not two already
      # running.
      #
      # Locked rather than merely re-read, so that the check and the destroy
      # cannot be separated by the very commit being checked for. Skipping is
      # always safe: the next run plans against what is there then.
      #
      # rubocop: disable CodeReuse/ActiveRecord -- the query belongs to the sync and has no finder
      def unchanged?(action)
        return true unless action.replica

        fresh = OC::WorkItems::ReplicatedWorkItem.lock.find_by(id: action.replica.id)

        fresh.present? &&
          fresh.state == action.replica.state &&
          fresh.source_blob_oid == action.replica.source_blob_oid
      end
      # rubocop: enable CodeReuse/ActiveRecord

      # Finishes a transfer this instance started, if that is what this
      # document is: one we froze, published by the instance we promised it to.
      #
      # Returns the row when it acted, nil when the document is nothing to do
      # with us. A stamp naming somebody else's directory is exactly that -- a
      # third instance watching two others exchange an item imports it as an
      # ordinary document, because that is all it is to them.
      def transfer_completion(action, document)
        stamp = document['transferred_from']
        return unless stamp.present? && stamp.start_with?("#{OC::WorkItems.instance_directory}/")

        row = surrendered_row(stamp)

        unless row
          # Already done. The stamp is permanent -- the new owner's document
          # carries it for good -- so every later version of that document
          # arrives here saying the same thing, and by then this is simply
          # their latest copy of an item we let go of. Falling through to the
          # ordinary import is what keeps a handed-over item tracking its new
          # owner's edits.
          return if action.replica

          # It claims to come from here, nothing here says it was given away,
          # and we hold no copy of it. Deferring rather than importing is the
          # point: importing would build a second copy of an item this instance
          # still holds, with nothing to say which was which. The freeze may
          # simply not have been pushed here yet, and a deferred row is re-read
          # on every run.
          return withhold(action, document, :deferred,
            'it says it came from here, but nothing here says it was given away')
        end

        # Intent and completion have to agree. The stamp is written by another
        # instance, so an instance we promised nothing to cannot finish a
        # transfer by claiming one.
        unless row.source_instance_uuid == @source_instance_uuid
          return withhold(action, document, :deferred,
            'it says it came from here, but it was promised to a different instance')
        end

        demote(action, document, row)
      end

      # rubocop: disable CodeReuse/ActiveRecord -- the query belongs to the sync and has no finder
      def surrendered_row(path)
        OC::WorkItems::ReplicatedWorkItem.find_by(
          project_id: @project.id, source_path: path, state: :surrendered)
      end
      # rubocop: enable CodeReuse/ActiveRecord

      # The end of a transfer, from the giving side: the item we froze comes
      # back as an ordinary copy of the new owner's document, and goes on
      # tracking their edits through the machinery every other copy uses.
      #
      # Two things are deliberate about how.
      #
      # The copy keeps the number the original had, rather than the number it
      # has on the instance that took it. Every link anybody ever wrote to
      # .../issues/42 -- in a comment, a commit message, another project, a
      # bookmark -- goes on resolving to the same item. The number is free by
      # then because the original was destroyed a moment earlier in this same
      # transaction.
      #
      # And the surrendered row is reused rather than replaced. Left behind, it
      # would name a path nothing writes any more and be invisible to the
      # reconcile, which skips surrendered rows by design -- so it would sit
      # there for ever, holding the item read-only through a row nobody could
      # find. Moving it is also what keeps the unique index satisfied without
      # anybody having to think about ordering.
      def demote(action, document, row)
        row.source_path = action.path

        replica = replicate(
          ImportReconciler::Action.new(
            kind: action.kind, path: action.path, oid: action.oid, replica: row,
            source_kind: action.source_kind, source_iid: action.source_iid),
          document,
          pinned_iid: row.work_item&.iid)

        # Our own directory still holds the document we published while the
        # item was ours, and it goes on saying we own it until something
        # rewrites it as a pointer. Every trigger that would have done so was
        # suppressed for the rebuild -- rightly, since the rest of that work is
        # ours to do -- so this one has to be asked for.
        #
        # It is only the demote that needs it. An ordinary import leaves
        # nothing behind to contradict: we never had a file at that path. Here
        # there is one, and until it changes any instance mirroring us reads
        # the item as belonging to two places at once.
        OC::WorkItems.enqueue_sync(replica.work_item) if replica&.work_item

        replica
      end

      # Whether this document describes an item that is already here.
      #
      # An instance that began as a copy of its peer -- database included, which
      # is how a staging installation usually starts -- already owns a native
      # record of everything the peer had at the time. Imported as replicas,
      # every one of them would double: the original, and a ghost-authored copy
      # under a new number, permanently forked from it.
      #
      # The identity is the same number and the same creation time. An iid
      # alone means nothing across instances -- two projects both have an issue
      # 1 -- but created_at is immutable, set once at microsecond precision,
      # and survives the database copy exactly. Two items sharing both are the
      # same item; anything else is a coincidence at a scale that does not
      # happen.
      #
      # A false negative is only today's behaviour (a duplicate), so the rule
      # can afford to be strict. A false positive would silently weld two
      # unrelated items together, so it cannot afford to be loose.
      def already_here(action, document)
        record = local_holder(action)
        return unless record

        # Nothing built from a peer's file can be "already here": it *is* the
        # copy. That includes the copy built from *this* file, which is what a
        # rebuild is looking at -- it has the source's number and the source's
        # creation time by construction, so an identity test would match every
        # rebuild against the record it is replacing and the item would never
        # be updated again.
        #
        # A matched row is the one that may: it says this record was already
        # ours, and re-reading the peer's file has to be able to reach the same
        # conclusion twice.
        holder_row = record.oc_replica
        return if holder_row && !holder_row.state_matched?

        record if same_creation_time?(record, document['created_at'])
      end

      # rubocop: disable CodeReuse/ActiveRecord -- the query belongs to the sync and has no finder
      def local_holder(action)
        relation = @project.public_send(RELATION_SYM.fetch(action.source_kind)) # rubocop: disable GitlabSecurity/PublicSend -- the method name comes from a fixed list

        relation.find_by(iid: action.source_iid)
      end
      # rubocop: enable CodeReuse/ActiveRecord

      # Compared at the precision the document carries. The column keeps
      # microseconds and the serialized form keeps milliseconds, so the two are
      # never equal on the nose even when they describe the same instant.
      #
      # Truncated rather than rounded, because that is what serializing did.
      def same_creation_time?(record, value)
        written = parse_time(value)
        return false unless written && record.created_at

        milliseconds(record.created_at) == milliseconds(written)
      end

      def parse_time(value)
        case value
        when ::String then Time.zone.parse(value)
        when ::Time, ::DateTime, ::Date then value.to_time
        end
      rescue ::ArgumentError
        nil
      end

      def milliseconds(time)
        (time.to_i * 1000) + (time.usec / 1000)
      end

      # Records that the peer's file and an item we already had are the same
      # item. Nothing is built, nothing is destroyed, and the record stays
      # fully ours -- the row is bookkeeping, so that the peer's references
      # resolve to it and the nightly stops re-reading a blob it has already
      # accounted for.
      def match(action, document, record)
        if action.replica&.state_matched?
          ::Gitlab::AppLogger.info(
            message: 'work items import kept its own copy of a matched item',
            project_id: @project.id, path: action.path)
        end

        upsert_replica(action, record, document['web_url'], state: :matched)
      end

      # Records that we looked at this file and are not building a record from
      # it, destroying whatever we built from an earlier version.
      def withhold(action, document, state, reason)
        OC::WorkItems.suppress_sync do
          ::ApplicationRecord.transaction do
            next unless unchanged?(action)

            release_record!(action.replica)

            upsert_replica(action, nil, document['web_url'], state: state, reason: reason)
          end
        end
      end

      # Lets go of whatever the row was pointing at, before it comes to mean
      # something else.
      #
      # For every state but one that means destroying the copy we built. A
      # matched row's record is not a copy: it was here before the peer's file
      # was, and nothing that happens to their file is a reason to delete it.
      # It does have to be let go of, though -- a row in any other state makes
      # its record read-only, so a matched row that keeps hold of a native
      # record while changing state would quietly freeze an item nobody
      # imported.
      def release_record!(replica)
        return unless replica

        if replica.state_matched?
          replica.issue = nil
          replica.merge_request = nil
        else
          replica.work_item&.destroy!
        end
      end

      # Why this merge request cannot be built yet, or nil if it can.
      #
      # Deferred rather than skipped: the commits usually turn up, just not in
      # the same push, and the source project may be a fork whose repository we
      # never receive. The reconciler re-checks deferred rows on every run
      # regardless of oid, precisely because nothing in the file will ever
      # change to signal that the blockage cleared.
      def deferral_reason(action, document)
        return unless action.source_kind == :merge_request

        diff = document['merge_request_diff']
        return 'the source document carries no merge request diff' if diff.blank?

        missing = DIFF_SHA_KEYS.reject { |key| commit_present?(diff[key]) }
        return if missing.empty?

        "diff commits not present: #{missing.join(', ')}"
      end

      def commit_present?(sha)
        sha.present? && @project.repository.commit(sha).present?
      end

      # A project holding replicas has to be a full participant in the sync:
      # it writes reference files for them, and remove_orphans has to run to
      # tidy up after them. Importing into a project that is not syncing would
      # leave a directory of files nothing maintains.
      #
      # Only ever turns sync on, and only for a project that has not made a
      # choice -- work_items_sync_opted_out? is checked before any of this.
      def start_syncing
        return if @project.work_items_sync_enabled?

        @project.enable_work_items_sync!(true)
      end

      # deep_dup because build_relation rewrites nested collections in place,
      # and the caller's document is theirs.
      def prepare(document, web_url)
        attributes = document.deep_dup.except(*ADDED_KEYS)
        rewrite_references!(attributes, web_url)
        attributes['description'] = described_by(attributes)
        attributes
      end

      # `#7` in a document from another instance means *their* issue 7. Left
      # alone it renders as a link to ours -- a different item, silently. See
      # ReferenceRewriter for what each outcome looks like.
      def rewrite_references!(attributes, web_url)
        path = source_project_path(attributes)

        rewriter = ReferenceRewriter.new(
          @project,
          source_instance_uuid: @source_instance_uuid,
          source_web_url: web_url,
          source_origin: source_origin(web_url, path),
          source_project_path: path,
          usernames: local_usernames)

        attributes['description'] = rewriter.rewrite(attributes['description'])

        Array(attributes['notes']).each do |note|
          note['note'] = rewriter.rewrite(note['note'])
        end

        @unresolved_references = rewriter.unresolved.uniq
      end

      def source_project_path(attributes)
        id = attributes['project_id'] || attributes['target_project_id']

        @source_paths[id.to_i] if id
      end

      # The peer's base URL, by subtracting the source project's path out of
      # the item's own URL.
      #
      # Subtraction rather than parsing off the scheme and host, because an
      # instance can live under a relative root -- https://host/gitlab -- and a
      # parse would silently drop it, sending every link built from this to a
      # path that does not exist.
      def source_origin(web_url, path)
        return if web_url.blank? || path.blank?

        marker = "/#{path}/-/"
        index = web_url.index(marker)

        web_url[0...index] if index
      end

      # {source username => local username}, local nil unless identity trust
      # matched them. The local name can differ from the source's, which is the
      # whole reason a mention has to be rewritten rather than left alone.
      #
      # rubocop: disable CodeReuse/ActiveRecord -- the query belongs to the sync and has no finder
      def local_usernames
        @local_usernames ||= @identities.to_h do |source_id, entry|
          entry = entry.stringify_keys if entry.respond_to?(:stringify_keys)
          source_username = entry.is_a?(::Hash) ? entry['username'] : nil
          local_id = @members_mapper.include?(source_id) ? @members_mapper.map[source_id] : nil

          [source_username, local_id && ::User.find_by(id: local_id)&.username]
        end.compact
      end
      # rubocop: enable CodeReuse/ActiveRecord

      # The number this copy already has, so that a rebuild keeps it.
      #
      # A rebuild destroys the record and makes another, and without this the
      # replacement takes whatever number the source's is or a freshly
      # allocated one -- so an item's number here could change every time the
      # instance that owns it edited it. Links written to it would rot silently.
      #
      # It matters most after a transfer. The demote pins the original's
      # number precisely so that everything ever written about the item still
      # resolves, and the very next edit from its new owner would have thrown
      # that away.
      #
      # Not for a matched row: its record is released rather than destroyed, so
      # the number is still taken by the item that is genuinely ours.
      def reusable_iid(action)
        replica = action.replica
        return if replica.nil? || replica.state_matched?

        replica.work_item&.iid
      end

      # Whether the source's number is free here.
      #
      # An overlap is ordinary rather than exceptional: the whole point of the
      # per-instance directories is that two instances can sync their own items
      # to one branch, so both will have an issue 1. Before this, the second
      # one to be imported simply failed on the unique index.
      #
      # rubocop: disable CodeReuse/ActiveRecord -- the query belongs to the sync and has no finder
      def iid_free?(action)
        relation = @project.public_send(RELATION_SYM.fetch(action.source_kind)) # rubocop: disable GitlabSecurity/PublicSend -- the method name comes from a fixed list

        !relation.where(iid: action.source_iid).exists?
      end
      # rubocop: enable CodeReuse/ActiveRecord

      # has_internal_id declares `track_if: -> { !importing? }`, so the record
      # RelationFactory hands back never allocates one for itself -- that is
      # exactly what preserves a supplied iid, and it means a record without
      # one would be saved with iid nil and fail NOT NULL.
      #
      # Turning importing off for the save lets the ordinary allocation run,
      # which advances the project's internal id counter properly. Picking
      # max(iid) + 1 by hand would not, and would collide with the next issue
      # anyone filed.
      def allocate_iid(record)
        record.importing = false
      end

      # Tells the project that this number is taken.
      #
      # has_internal_id tracks an externally supplied iid in a before_create
      # guarded by `track_if: -> { !importing? }`, and an import is importing by
      # definition -- so keeping the source's number leaves the project's
      # counter behind it. That is not a cosmetic gap. The next issue anyone
      # files here is handed a number this import already took, the insert
      # fails on the unique index, and the rollback reverts the counter
      # increment along with it -- so the retry generates the same number and
      # fails again. The project stops being able to create issues at all,
      # permanently, until someone fixes the counter by hand.
      #
      # "The peer's numbers run ahead of ours" is not an edge case either; it
      # is the ordinary shape of an import.
      #
      # The flag the skipped callback would have consumed is still set, because
      # RelationFactory assigned the iid through the writer rather than the
      # column.
      def track_iid!(record)
        helper = record.is_a?(::MergeRequest) ? :track_target_project_iid! : :track_namespace_iid!

        record.public_send(helper) # rubocop: disable GitlabSecurity/PublicSend -- the method name comes from a fixed list
      end

      def build(action, attributes)
        relation_key = RELATION_SYM.fetch(action.source_kind).to_s

        build_relation(relation_key, relations_tree.fetch(relation_key, {}), attributes)
      end

      # RelationFactory builds one level. Nested collections -- notes, their
      # award emoji, label links, resource events -- have to be turned into
      # objects first, or assigning the raw hash raises
      # AssociationTypeMismatch.
      #
      # This mirrors Base::RelationTreeRestorer#build_relation rather than
      # calling it, because the restorer is built to import a whole project:
      # its restore runs update_params!, which assigns the exported project's
      # attributes over the receiving project's own. Fine when the project is
      # the thing being created, catastrophic when it already exists and
      # belongs to someone else.
      def build_relation(relation_key, definition, data_hash)
        # The author sub-hash is not a record to build. RelationFactory reads
        # it for the byline it puts on a note and then discards it.
        return data_hash if relation_key == 'author'

        definition.each do |sub_key, sub_definition|
          sub_hash = data_hash[sub_key]
          next unless sub_hash

          built =
            if sub_hash.is_a?(Array)
              sub_hash.filter_map { |entry| build_relation(sub_key, sub_definition, entry) }.presence
            else
              build_relation(sub_key, sub_definition, sub_hash)
            end

          data_hash[sub_key] = built if built
        end

        ::Gitlab::ImportExport::Project::RelationFactory.create(
          relation_index: 0,
          relation_sym: relation_key.to_sym,
          relation_hash: data_hash,
          members_mapper: @members_mapper,
          object_builder: ::Gitlab::ImportExport::Project::ObjectBuilder,
          user: ghost_user,
          importable: @project,
          # Stamped on every record as imported_from. Anything but none puts
          # GitLab's own "Imported" badge beside the replica banner, which
          # says the same thing twice.
          import_source: ::Import::SOURCE_NONE,
          # Nothing to exclude: these documents were produced by the same
          # import_export.yml `only:` lists that define the excluded set, so
          # they cannot contain an excluded attribute. What they do contain is
          # ADDED_KEYS, which is ours to strip and not described there.
          excluded_keys: [])
      end

      def ghost_user
        @ghost_user ||= ::Users::Internal.in_organization(@project.organization_id).ghost
      end

      # The same shape the exporter walked, read back the other way.
      def relations_tree
        @relations_tree ||= ::Gitlab::ImportExport::AttributesFinder
          .new(config: ::Gitlab::ImportExport::Config.new.to_h)
          .find_relations_tree(:project, include_import_only_tree: true)
          .deep_stringify_keys
      end

      # Names the original author in the body when we could not attribute the
      # record to a local user.
      #
      # Upstream writes this only onto notes (Base::RelationFactory's
      # set_note_author), leaving an imported issue silently attributed to the
      # importer. So we write it ourselves, and the name comes from the peer's
      # ids.yml -- the document carries only author_id, which is precisely why
      # that file records display names.
      def described_by(attributes)
        author_id = attributes['author_id']
        description = attributes['description']
        return description if author_id.blank? || @members_mapper.include?(author_id)

        [description.presence, byline(author_id, attributes['created_at'])].compact.join("\n\n")
      end

      def byline(author_id, created_at)
        entry = @identities[author_id.to_i] || {}
        entry = entry.stringify_keys if entry.respond_to?(:stringify_keys)
        name = entry['name'].presence || entry['username'].presence || 'an unknown user'

        "*By #{name}#{on(created_at)} (imported from GitLab)*"
      end

      def on(created_at)
        date = created_at.presence && ::Date.parse(created_at.to_s)
        date ? " on #{date.iso8601}" : ''
      rescue ::Date::Error
        ''
      end

      # What this instance decided the source's ids mean here, keyed the way a
      # reader encounters them: locally first.
      #
      # Projects are flat -- everything in a source document belongs to the
      # source project, and everything built from it belongs to this one -- so
      # the source project id is read off whichever project reference the
      # document carried. Groups are deliberately absent: nothing in an import
      # maps a source group to a local one, since labels are found or created
      # by title rather than by group.
      def identity_map(record, source_project_id, source_label_groups)
        projects = source_project_id ? { record.project_id => source_project_id } : {}

        {
          'projects' => projects,
          'groups' => group_identities(record, source_label_groups),
          'users' => @members_mapper.local_to_source
        }.reject { |_kind, map| map.blank? }
      end

      # A group reaches a work item document only through a label it owns, so
      # that is where the correspondence has to be read from.
      #
      # Paired by title because that is how ObjectBuilder paired them: it finds
      # an existing label by title across the project's ancestor groups, or
      # creates one. So a source group label and the local label standing in for
      # it share a title, and the group each belongs to is the pair.
      #
      # Captured from the document before building, since building replaces the
      # nested hashes with objects and the source ids go with them.
      def source_label_groups(document)
        Array(document['label_links']).each_with_object({}) do |link, groups|
          label = link['label']
          next unless label.is_a?(::Hash) && label['group_id']

          groups[label['title']] = label['group_id']
        end
      end

      def group_identities(record, source_label_groups)
        return {} if source_label_groups.blank?

        record.label_links.each_with_object({}) do |link, groups|
          label = link.label
          source_group_id = label && source_label_groups[label.title]
          next unless source_group_id && label.group_id

          groups[label.group_id] = source_group_id
        end
      end

      def upsert_replica(action, record, web_url, state:, reason: nil, identities: nil, unresolved: nil)
        replica = action.replica || OC::WorkItems::ReplicatedWorkItem.new(
          project: @project,
          source_instance_uuid: @source_instance_uuid,
          source_path: action.path)

        replica.assign_attributes(
          source_kind: action.source_kind,
          source_iid: action.source_iid,
          source_blob_oid: action.oid,
          source_web_url: web_url,
          state: state,
          reason: reason)

        replica.identities = identities if identities
        replica.unresolved = unresolved

        if record
          replica.work_item = record
        else
          # A withheld row keeps the oid so it is not re-read every night, but
          # must not still point at a record we have just destroyed.
          replica.issue = nil
          replica.merge_request = nil
        end

        replica.save!

        replica
      end
    end
  end
end
