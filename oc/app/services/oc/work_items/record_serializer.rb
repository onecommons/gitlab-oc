# frozen_string_literal: true

module OC
  module WorkItems
    # Serializes one file of the sync branch -- an Issue, a MergeRequest, or
    # the commit notes of a single commit -- into the same JSON document a
    # project export (ndjson) would produce, then into stable YAML.
    #
    # The attribute/association schema comes straight from
    # lib/gitlab/import_export/project/import_export.yml via AttributesFinder,
    # so the output is restorable by GitLab's own import machinery. The only
    # deliberate deviations:
    #   * merge_request_diff keeps its own row but loses both of its child
    #     relations -- the per-file patch text and the per-commit rows are the
    #     code, which lives in this same repository, and they outweigh
    #     everything else in the document by an order of magnitude
    #   * a top-level `_schema` header and `web_url` key are added
    #   * the database ids a document carries are resolved to stable
    #     identifiers in ids.yml, built as a side effect of serializing
    #   * commit notes are grouped per commit under a `notes` key, since the
    #     export relation is a flat list with no natural per-file unit
    #   * the label and milestone catalogs reach past the project into its
    #     ancestor groups, which a project-scoped export never does
    #   * confidential records/notes are filtered on non-private projects
    #     ("match visibility": repository readers on private projects are
    #     Reporter+, who can see confidential issues anyway)
    class RecordSerializer
      RELATION_KEYS = { 'Issue' => :issues, 'MergeRequest' => :merge_requests }.freeze
      COMMIT_NOTES_KEY = :commit_notes

      # Whole-project catalogs rather than one file per record: there are few
      # of them, they are read as a set, and neither has an iid that would make
      # a good file name for a group-owned one.
      CATALOG_KEYS = %i[labels milestones].freeze

      # ids.yml, which resolves every database id the branch mentions to the
      # identifier a reader can actually act on. Unlike the other three this
      # relation name is ours, not a key into import_export.yml -- nothing
      # upstream produces this file.
      IDENTITIES_KEY = :ids

      # Which `*_id` attribute belongs to which kind. Keyed by attribute name
      # rather than by relation: across the whole export schema a given name
      # always means the same thing, and several relations we do not serialize
      # today would be covered for free if a GitLab upgrade added them.
      #
      # `created_by_id` and `owner_id` are deliberately absent -- they belong
      # to project_members and pipeline_schedules, neither of which is in our
      # trees. The guard in the spec fails if that stops being true.
      IDENTITY_KEYS = {
        'project_id' => :projects,
        'source_project_id' => :projects,
        'target_project_id' => :projects,
        'group_id' => :groups,
        'author_id' => :users,
        'updated_by_id' => :users,
        'closed_by_id' => :users,
        'last_edited_by_id' => :users,
        'merge_user_id' => :users,
        'resolved_by_id' => :users,
        'latest_closed_by_id' => :users,
        'merged_by_id' => :users,
        'user_id' => :users
      }.freeze

      # `*_id` attributes that are already stable identifiers, or are not ids
      # at all. Listed rather than merely omitted so that their appearance in a
      # document is a decision on record and not an oversight -- the spec
      # asserts that every id-shaped attribute in the export schema is either
      # resolved above or named here.
      #
      # noteable_id and review_id only reach us through commit_notes, the one
      # relation exported as a raw row. Both are null on a commit note -- the
      # sha in commit_id names the noteable, and a batch-comment review belongs
      # to a merge request -- so compaction drops them. Neither names a user, a
      # project or a group in any case.
      UNRESOLVED_ID_KEYS = %w[commit_id discussion_id noteable_id review_id].freeze

      # Ids that mean nothing outside this instance and say nothing about the
      # item: the project's own namespace and organization. Dropped from every
      # document; upstream's importer discards namespace_id and recomputes it
      # from the receiving project anyway.
      LOCAL_ONLY_ID_KEYS = %w[namespace_id organization_id].freeze

      # Emission order of ids.yml, widest scope first.
      IDENTITY_KINDS = %i[projects groups users].freeze

      # Dropped from the merge request's diff row. Both are moved by background
      # housekeeping -- MergeRequestDiff's `without_files` transition and
      # migrate_files_to_external_storage! -- so keeping them would rewrite the
      # file of a merge request nobody has touched in months. Neither tells a
      # reader of an archive anything: `state` describes whether this instance
      # still holds the diff rows we are not exporting anyway.
      DIFF_HOUSEKEEPING_ATTRIBUTES = %i[state updated_at].freeze

      # Bumped whenever the shape of a file changes in a way a consumer would
      # have to know about: adding or removing our own keys, regrouping
      # records, renaming a directory. Changes to the embedded record schema
      # are upstream's and are reported by the import/export version instead.
      SCHEMA_VERSION = 1

      # `<relation>@<layout version>`, e.g. `issues@1`.
      #
      # Deliberately carries nothing that upstream controls. The import/export
      # version belongs in the commit trailer instead: putting it here would
      # make an upstream bump change the first line of every file, so a release
      # that touched a relation we do not even sync would rewrite the whole
      # branch. Both parts of this string are ours, and both only move when we
      # change the serializer -- which changes the body of every file anyway.
      SCHEMA_PATTERN = /\A(?<type>[a-z_]+)@(?<version>\d+)\z/

      # System notes GitLab writes as "mentioned in issue #7" -- see
      # SystemNotes::IssuablesService#cross_reference and its
      # `cross_reference_note_prefix`. The bodies come from a fixed template
      # rather than being user prose, which is what makes matching them by
      # pattern sound.
      #
      # Identified by the prefix rather than by system_note_metadata.action,
      # which would be the obvious key: commit_notes is the one relation whose
      # export tree has no system_note_metadata, and a commit carries these
      # notes like any other noteable. The `system` flag is enough to keep an
      # ordinary comment that happens to start the same way out of it.
      CROSS_REFERENCE_PREFIX = /\Amentioned in /i

      # Keys whose value is null, an empty list or an empty map are left out:
      # about half of a merge request document was lines like `merge_error:`
      # saying nothing. Absent and null restore identically, since a missing
      # attribute simply is not assigned.
      #
      # Except where the column's database default is not null, in which case
      # dropping the key would restore the default instead. Of the four such
      # columns across everything we serialize, only this one matters:
      # `lock_version` defaults to 0 and `template` to false, both
      # indistinguishable from null in practice, but allow_maintainer_to_push
      # defaults to *true* -- so omitting a null would quietly grant
      # maintainers push access to a fork's branch.
      KEEP_WHEN_BLANK = %w[allow_maintainer_to_push].freeze

      # Distinguishes a file that points at an item from one that holds it.
      # `issues@1` is an issue; `issue_reference@1` is a note saying the real
      # issue lives on another instance.
      REFERENCE_SUFFIX = '_reference'

      # Returned instead of a document when the file must be left exactly as it
      # is: neither rewritten nor deleted.
      #
      # A third outcome is needed because nil already means "delete this file",
      # and a frozen item needs the opposite. Its document has to stay on the
      # branch until the new owner's copy replaces it -- deleting it would
      # withdraw the item from every instance mirroring it for as long as the
      # transfer takes, which can be days.
      LEAVE_ALONE = :leave_alone
      # The leading segment is any instance's uuid directory, captured rather
      # than pinned. The uuid is deliberately not interpolated: a constant is
      # built at class load, when CurrentSettings can still be the uuid-less
      # fake, and would freeze whatever it got. Callers compare the directory
      # themselves -- the writer against its own, the importer against a peer's.
      DOCUMENT_PATTERN = %r{
        \A(?<dir>[^/]+)/
        (?:(?<relation>issues|merge_requests)/(?<iid>\d+)|(?<notes>commit_notes)/(?<sha>\h{40}))
        \.yml\z
      }x
      def self.reference_key(relation_key)
        :"#{relation_key.to_s.singularize}#{REFERENCE_SUFFIX}"
      end

      def self.reference?(schema)
        schema.to_s.end_with?("#{REFERENCE_SUFFIX}@#{SCHEMA_VERSION}")
      end

      def self.catalog_file_path(key)
        branch_path("#{key}.yml")
      end

      # The map back out of a committed ids.yml, so an incremental pass can add
      # to what is already there instead of replacing it with the little it saw.
      # A file we cannot read as our own is treated as absent and rebuilt.
      def self.parse_identities(yaml)
        parsed = YAML.safe_load(yaml.to_s, permitted_classes: [Date, Time])
        return {} unless parsed.is_a?(Hash) && parsed['_schema'] == schema_id(IDENTITIES_KEY)

        IDENTITY_KINDS.each_with_object({}) do |kind, map|
          found = parsed[kind.to_s]
          map[kind.to_s] = found if found.is_a?(Hash)
        end
      rescue ::Psych::Exception
        {}
      end

      def self.identities_file_path
        branch_path("#{IDENTITIES_KEY}.yml")
      end

      def self.file_path(relation_key, iid)
        branch_path("#{relation_key}/#{iid}.yml")
      end

      def self.commit_notes_file_path(commit_id)
        branch_path("#{COMMIT_NOTES_KEY}/#{commit_id}.yml")
      end

      # Everything this instance writes hangs off its own uuid directory. This
      # is the single place that knows it, so the readers that look a path back
      # up -- SyncService#remove, #read_identities, #file_action -- inherit the
      # prefix without needing to know about it.
      #
      # Peer paths are never built here: the importer reads them off the branch
      # rather than constructing them.
      def self.branch_path(suffix)
        "#{OC::WorkItems.instance_directory}/#{suffix}"
      end

      # The inverse of file_path: what a path on the branch refers to, or nil
      # when it is not a document at all. Catalogs and ids.yml deliberately do
      # not match -- they describe a whole project rather than one record, and
      # every caller here is asking about records.
      def self.parse_path(path)
        match = DOCUMENT_PATTERN.match(path.to_s)
        return unless match

        if match[:relation]
          { directory: match[:dir], relation: match[:relation].to_sym, iid: match[:iid].to_i }
        else
          { directory: match[:dir], relation: COMMIT_NOTES_KEY, commit_id: match[:sha] }
        end
      end

      # Identifies what a file on the branch is, so a consumer can tell an
      # issue document from a merge request document from a commit notes
      # document without inferring it from the path, and can refuse a file
      # whose format it does not know. See SCHEMA_PATTERN for the grammar.
      #
      # The relation name is the key back into import_export.yml, and is also
      # the directory or file name below the instance directory -- except for
      # `ids`, which is ours alone and has no upstream relation. Which export
      # schema a file's fields follow comes from the commit that wrote it --
      # `git log -1 -- <uuid>/issues/42.yml` -- which is exact per file and
      # cannot go stale the way a header can.
      def self.schema_id(relation_key)
        "#{relation_key}@#{SCHEMA_VERSION}"
      end

      # Returns the export hash for the record, nil when the record must not
      # appear in the sync branch (confidential issue on a non-private
      # project), or LEAVE_ALONE.
      #
      # A replica row does not by itself mean "write a reference": it means
      # this record and some path on the branch are related, and which of the
      # four ways depends on the state. Three of them are transfer -- see
      # OC::WorkItems::ReplicatedWorkItem.
      def serialize(record)
        replica = record.oc_replica

        if replica
          return LEAVE_ALONE if replica.state_surrendered?
          return serialize_reference(record, replica) if replica.read_only?
        end

        document = serialize_document(record)

        # The signal the old owner is waiting for, and the only part of a
        # transfer that travels through the files rather than through anybody's
        # database. It says: this document is the item that used to live at
        # that path, so whoever owns that path may stop holding it.
        return document if document.nil? || !replica&.state_adopted?

        document.merge('transferred_from' => replica.source_path)
      end

      def serialize_document(record)
        key = relation_key(record)
        hash = ::Gitlab::Json::SafeParser.parse(record.to_json(relation_options(key)))

        return unless filter_confidential!(hash, record)

        strip_local_ids!(hash)
        sort_collections!(hash)
        compact_blanks!(hash)
        collect_identities!(hash, record.project)
        # Assigned only when there is something to say. Compacting the hash
        # afterwards would be the obvious alternative and is wrong: it would
        # take KEEP_WHEN_BLANK's deliberate nils with it.
        uploads = collect_uploads(hash, record.project)
        hash['uploads'] = uploads if uploads
        hash['web_url'] = ::Gitlab::UrlBuilder.build(record)
        schema_header(key).merge(hash)
      end

      # A replica is another instance's item, held here read-only. Serializing
      # its contents would republish them: this branch would claim an item it
      # only mirrors, and in a mesh of instances the same issue would multiply
      # into a copy per instance, each looking equally original. So the file
      # says where the real one is instead.
      #
      # The `ids` block is the one thing here that cannot be worked out from
      # the branch. Both instances publish an ids.yml, and between them they
      # explain every id either one uses -- but neither says that *their* user
      # 12 and *our* user 500 are the same person. That was a decision this
      # instance made while importing, from a verified email or a matching
      # username, and without recording it the two directories cannot be lined
      # up by anyone reading them later.
      #
      # Keyed locally, because a reader arrives here holding a local id: they
      # are looking at our issue 7 and want to know which of the source's items
      # and people it stands for. Empty when nothing was mapped -- with
      # identity trust off, every author is the ghost user, and "everyone
      # unmatched is the same local id" is not a correspondence worth writing
      # down.
      def serialize_reference(record, replica)
        schema_header(self.class.reference_key(relation_key(record))).merge(
          'source_path' => replica.source_path,
          'source_web_url' => replica.source_web_url,
          'web_url' => ::Gitlab::UrlBuilder.build(record),
          'ids' => sorted_identities(replica.identities)
        ).compact
      end

      def sorted_identities(identities)
        return if identities.blank?

        # Same ordering rule as ids.yml: a document that has not changed has to
        # serialize to the same bytes, or the branch never converges.
        IDENTITY_KINDS.filter_map do |kind|
          found = identities[kind.to_s]
          next if found.blank?

          # Integer keys, matching ids.yml. They arrive as strings because the
          # row stores JSON, where an object key can only ever be a string --
          # left alone they would serialize quoted, and the same id would read
          # as `'12':` here and `12:` one file away.
          [kind.to_s, found.sort_by { |id, _| id.to_i }.to_h.transform_keys(&:to_i)]
        end.to_h.presence
      end

      def to_yaml(record)
        hash = serialize(record)
        return hash if hash == LEAVE_ALONE

        hash && YAML.dump(hash)
      end

      # Commit notes have no iid and no parent record to hang off, so one file
      # holds every note on one commit. Returns nil when nothing is left to
      # write, which the caller turns into a file deletion.
      def serialize_commit_notes(project, commit_id, notes)
        entries = notes.map { |note| commit_note_entry(note) }
        entries = filter_confidential_notes(entries, project)

        return if entries.empty?

        sort_collections!(entries)
        compact_blanks!(entries)
        collect_identities!(entries, project)

        schema_header(COMMIT_NOTES_KEY).merge(
          {
            'commit_id' => commit_id,
            'notes' => entries,
            'uploads' => collect_uploads(entries, project),
            'web_url' => ::Gitlab::Routing.url_helpers.project_commit_url(project, commit_id)
          }.compact
        )
      end

      def to_yaml_commit_notes(project, commit_id, notes)
        hash = serialize_commit_notes(project, commit_id, notes)
        hash && YAML.dump(hash)
      end

      # The project's label or milestone catalog. Unlike the per-record files
      # this is not restricted to what the export would produce for a project:
      # it also carries the ancestor groups' labels and milestones, which a
      # work item here can reference and which a project-scoped export leaves
      # behind. No schema change is needed for that -- the attribute lists for
      # both already carry `group_id`, and a label already reports its `type`.
      #
      # Returns nil when the project has neither its own nor any inherited
      # records, which the caller turns into a file deletion.
      def serialize_catalog(project, key, records)
        entries = records.map { |record| catalog_entry(project, key, record) }

        return if entries.empty?

        sort_collections!(entries)
        compact_blanks!(entries)
        collect_identities!(entries, project)

        schema_header(key).merge(
          { key.to_s => entries, 'uploads' => collect_uploads(entries, project) }.compact
        )
      end

      def to_yaml_catalog(project, key, records)
        hash = serialize_catalog(project, key, records)
        hash && YAML.dump(hash)
      end

      # Every id this serializer has resolved since it was created, which
      # SyncService keeps for a whole pass. Built as a side effect of
      # serializing rather than by a separate query, which is what keeps it
      # honest: an id is recorded only if it survived into a document a reader
      # of the branch can see, so a stripped internal note cannot name its
      # author here.
      #
      # {kind => {id => identifier}}, unsorted; to_yaml_identities orders it.
      def identities
        @identities ||= {}
      end

      # ids.yml, which unlike every other file on the branch is not a snapshot
      # of records but an index across them. Kept out of the documents
      # themselves so that a rename -- of a user, a project, a group -- rewrites
      # one file rather than every file that mentions it.
      #
      # Returns nil when there is nothing to write, which the caller turns into
      # a file deletion.
      def serialize_identities(map)
        entries = IDENTITY_KINDS.filter_map do |kind|
          found = map[kind.to_s] || map[kind]
          next if found.blank?

          [kind.to_s, found.sort.to_h]
        end.to_h

        return if entries.empty?

        schema_header(IDENTITIES_KEY).merge(entries)
      end

      def to_yaml_identities(map)
        hash = serialize_identities(map)
        hash && YAML.dump(hash)
      end

      def file_path(record)
        self.class.file_path(relation_key(record), record.iid)
      end

      def preloads(key)
        relation_options(key)[:preload]
      end

      def commit_notes_preloads
        preloads(COMMIT_NOTES_KEY)
      end

      def relation_key(record)
        record.is_a?(::MergeRequest) ? :merge_requests : :issues
      end

      private

      def schema_header(relation_key)
        { '_schema' => self.class.schema_id(relation_key) }
      end

      # A group label's `priorities` span every project that prioritised it, so
      # exporting them wholesale would tell readers of this repository what
      # other projects have done with a shared label. GitLab's own export never
      # reaches this case (it only exports project labels), so trim it here.
      def catalog_entry(project, key, record)
        hash = ::Gitlab::Json::SafeParser.parse(record.to_json(relation_options(key)))

        priorities = hash['priorities']
        priorities.select! { |priority| priority['project_id'] == project.id } if priorities.is_a?(Array)

        hash
      end

      # Unlike every other relation on the branch, commit_notes has no
      # `included_attributes` entry in import_export.yml, so `to_json` hands
      # back the raw row including its primary key. Drop it: DB ids are
      # instance-local noise, they appear nowhere else on the branch, and the
      # importer discards them anyway.
      def commit_note_entry(note)
        hash = ::Gitlab::Json::SafeParser.parse(note.to_json(relation_options(COMMIT_NOTES_KEY)))
        hash.delete('id')
        strip_local_ids!(hash)
        hash
      end

      def relation_options(key)
        @relation_options ||= {}
        @relation_options[key] ||= begin
          tree = attributes_finder.find_root(:project)
          options = tree[:include].find { |entry| entry.key?(key) }.fetch(key).deep_dup

          trim_merge_request_diff!(options) if key == :merge_requests

          options
        end
      end

      # Keeps the diff row, drops what hangs off it.
      #
      # The row is eleven scalars and costs a few hundred bytes; its children
      # are one entry per changed file carrying the whole patch, plus one per
      # commit carrying the full message. On an ordinary merge request that is
      # the difference between a 1.5 KB document and a 35 KB one, for content
      # the repository already holds.
      #
      # What the row buys, beyond the shas the merge request already carries in
      # diff_head_sha and friends, is base_commit_sha and start_commit_sha --
      # the other two corners of the three-dot diff, so a reader can reproduce
      # exactly what GitLab showed rather than approximate it.
      def trim_merge_request_diff!(options)
        entry = options[:include]&.find { |item| item.key?(:merge_request_diff) }
        diff = entry && entry[:merge_request_diff]
        return unless diff

        diff.delete(:include)
        diff.delete(:preload)
        diff[:only] -= DIFF_HOUSEKEEPING_ATTRIBUTES if diff[:only]

        # Preload the row itself but nothing below it, matching what is now
        # serialized -- otherwise every merge request loads its diff files.
        options[:preload][:merge_request_diff] = nil if options[:preload]&.key?(:merge_request_diff)
      end

      def attributes_finder
        ::Gitlab::ImportExport::AttributesFinder.new(config: ::Gitlab::ImportExport::Config.new.to_h)
      end

      # Returns false when the whole record must be dropped.
      #
      # Confidential content is excluded unless a private project has opted in:
      # confidential issues are dropped entirely and internal notes stripped.
      def filter_confidential!(hash, record)
        return true if record.project.sync_confidential_work_items?
        return false if record.try(:confidential)

        notes = hash['notes']
        hash['notes'] = visible_notes(notes, record.project) if notes.is_a?(Array)
        true
      end

      # Defence in depth for the commit notes path: only notes on issues can
      # be confidential (Note#noteable_can_have_confidential_note?), so the
      # flag itself should never drop anything -- but a commit can carry a
      # cross-reference note like any other noteable, and the branch must not
      # become the one place something leaks from.
      def filter_confidential_notes(entries, project)
        return entries if project.sync_confidential_work_items?

        visible_notes(entries, project)
      end

      def visible_notes(notes, project)
        notes.reject do |note|
          confidential_note?(note) || hidden_cross_reference?(note, project)
        end
      end

      def confidential_note?(note)
        note['confidential'] || note['internal']
      end

      # Mirrors Note#system_note_with_references?: an action known to carry
      # references is always scanned, and anything else only when it opens with
      # the cross-reference prefix. The prefix alone is not enough -- a
      # `relate` note reads "marked this issue as related to #5", names an
      # issue, and starts with nothing in particular.
      #
      # The prefix is upstream's too: SystemNotes::IssuablesService.
      # cross_reference? is the same anchored, case-insensitive test.
      #
      # Falling back to the prefix also covers commit_notes, the one relation
      # whose export tree carries no system_note_metadata to read an action
      # from.
      def cross_reference?(note)
        return false unless note['system']

        action = note.dig('system_note_metadata', 'action')
        return true if ::SystemNoteMetadata::TYPES_WITH_CROSS_REFERENCES.include?(action)

        note['note'].to_s.match?(CROSS_REFERENCE_PREFIX)
      end

      # A cross-reference system note names whatever mentioned this record --
      # "mentioned in issue #7". GitLab writes those unconditionally and hides
      # them when rendering, per reader: Note#system_note_visible_for? drops
      # one whose referenced object the reader cannot see. A file on a branch
      # has no reader to filter for, so the note would tell anyone who can
      # clone the repository that #7 exists.
      #
      # A note is dropped when *any* of its references is one the branch's
      # audience could not otherwise reach.
      def hidden_cross_reference?(note, project)
        return false unless cross_reference?(note)

        body = note['note'].to_s

        reference_kinds.any? do |pattern, id_key, feature|
          body.to_enum(:scan, pattern).any? do
            hidden_reference?(project, ::Regexp.last_match, id_key, feature)
          end
        end
      end

      # GitLab's own reference grammar rather than one of our own. These are
      # memoized class-level regexes built from Gitlab::PathRegex, and each
      # composes Project.reference_pattern -- which separates `namespace` from
      # `project` for us, so the awkward case falls out for free: a sibling in
      # the same namespace is written bare (`sibling#7`, no slash), and here it
      # is simply a match with no `namespace` capture.
      #
      # The third element is the feature a reader needs on the referenced
      # project to be allowed to know the thing exists at all.
      def reference_kinds
        @reference_kinds ||= [
          [::Issue.reference_pattern, :issue, :issues_access_level],
          [::MergeRequest.reference_pattern, :merge_request, :merge_requests_access_level],
          [::Commit.reference_pattern, :commit, :repository_access_level]
        ]
      end

      def hidden_reference?(source, match, id_key, feature)
        target = referenced_project(source, match)

        # A renamed or deleted project cannot be judged at all -- and with no
        # project there is nothing to run the confidential check against.
        return true if target.nil?
        return true if target.id != source.id && !readable_with?(source, target, feature)

        id_key == :issue && confidential_iids(target).include?(match[:issue].to_i)
      end

      def referenced_project(source, match)
        return source if match[:project].blank?

        namespace = match[:namespace].presence || source.namespace.full_path

        resolve_project("#{namespace}/#{match[:project]}")
      end

      # Is `target` reachable by everyone who can read `source`'s repository?
      #
      # Public and internal projects have audiences wider than any membership,
      # so the target has to be at least as visible as the source. A private
      # project's audience is its own members, which makes a private sibling
      # under the same root namespace the same owner's material -- naming it
      # discloses nothing outside that ownership boundary. A private project
      # belonging to anyone else is not named at all.
      #
      # The residue, deliberately accepted: a member of one private project who
      # is not in the root group still learns a sibling's path.
      def readable_with?(source, target, feature)
        nameable?(source, target) && feature_reachable?(target, feature)
      end

      # Whether naming `target` at all is safe for everyone who can read
      # `source`'s repository. Separate from the per-feature check because
      # ids.yml maps a project id to its path without referring to anything
      # inside it -- a fork's `source_project_id` is a foreign project, and
      # resolving it to a path would disclose the fork's existence just as a
      # cross-reference would.
      def nameable?(source, target)
        return true if target.id == source.id
        return target.visibility_level >= source.visibility_level unless source.private?

        target.visibility_level > ::Gitlab::VisibilityLevel::PRIVATE ||
          target.root_ancestor == source.root_ancestor
      end

      # A project can be public while keeping its issues for members only, in
      # which case naming one of them discloses just as much.
      def feature_reachable?(target, feature)
        level = target.project_feature&.public_send(feature) # rubocop:disable GitlabSecurity/PublicSend -- the method name comes from a fixed list

        level.to_i >= ::ProjectFeature::ENABLED
      end

      # Memoized for the life of the serializer, which SyncService keeps for a
      # whole pass -- so a project referenced by ten thousand issues is
      # resolved once. Staleness within a single pass is not a concern: the
      # next one re-reads.
      def resolve_project(full_path)
        @projects_by_path ||= {}
        return @projects_by_path[full_path] if @projects_by_path.key?(full_path)

        @projects_by_path[full_path] = ::Project.find_by_full_path(full_path)
      end

      # Walks a finished document -- after confidential filtering and after
      # compaction, so it sees exactly what a reader of the file will see --
      # and resolves every id it recognises.
      #
      # Resolution happens here rather than being deferred because `source` is
      # part of the answer for a project: whether a path may be named at all
      # depends on which project's branch the document is bound for.
      def collect_identities!(document, source)
        each_identity(document) do |kind, id|
          found = identities[kind.to_s] ||= {}
          next if found.key?(id)

          identifier = resolve_identity(kind, id, source)
          found[id] = identifier if identifier
        end
      end

      def each_identity(value, &block)
        case value
        when Hash
          value.each do |key, nested|
            kind = IDENTITY_KEYS[key]
            yield(kind, nested) if kind && nested.is_a?(Integer)

            each_identity(nested, &block)
          end
        when Array
          value.each { |nested| each_identity(nested, &block) }
        end
      end

      def resolve_identity(kind, id, source)
        case kind
        when :projects then project_identity(id, source)
        when :groups then find_group(id)&.full_path
        else user_identity(id)
        end
      end

      # Gated exactly like a cross-reference, minus the per-feature part: a
      # path in ids.yml says the project exists and nothing about its contents.
      # Without this a fork's source_project_id -- a project belonging to
      # someone else entirely -- would be resolved to a path here and undo what
      # the cross-reference filter is for.
      #
      # Groups need no such gate: a group only reaches a document by owning a
      # label or milestone this project inherits, so it is an ancestor and its
      # path is a prefix of one the reader already has. Nor do users, once the
      # walk runs on the filtered document.
      def project_identity(id, source)
        target = find_project(id)
        return unless target && nameable?(source, target)

        target.full_path
      end

      # `name` is the display name the web UI shows against a comment, and is
      # the only one of the three that is not an identifier -- it is neither
      # unique nor a way to find the user again. It is here because the export
      # inlines it only for the author of a record: nothing names the user
      # behind an updated_by_id, an award emoji or an assignee, so without it
      # those ids cannot be rendered the way GitLab renders them.
      def user_identity(id)
        user = find_user(id)
        return unless user

        identity = { 'username' => user.username, 'name' => user.name }
        # Blank unless the user chose to publish one. It is a verified address
        # they own (User#public_email_verified), and it is what GitLab's own
        # importer matches on -- see ImportExport::MembersMapper#get_email.
        identity['public_email'] = user.public_email if user.public_email.present?
        identity
      end

      # rubocop: disable CodeReuse/ActiveRecord -- the query belongs to the sync and has no finder
      def find_project(id)
        @projects_by_id ||= {}
        @projects_by_id.fetch(id) { @projects_by_id[id] = ::Project.find_by(id: id) }
      end

      def find_group(id)
        @groups_by_id ||= {}
        @groups_by_id.fetch(id) { @groups_by_id[id] = ::Group.find_by(id: id) }
      end

      def find_user(id)
        @users_by_id ||= {}
        @users_by_id.fetch(id) { @users_by_id[id] = ::User.find_by(id: id) }
      end
      # rubocop: enable CodeReuse/ActiveRecord

      # The files a document points at but does not contain: images dragged
      # into a comment, logs attached to an issue. The file itself lives
      # outside the repository, so a clone of this branch has the prose and not
      # the attachments -- this at least says what is missing, where to fetch
      # it while this instance is up, and enough about each one to recognise a
      # copy that came from somewhere else.
      #
      # One list for the whole document rather than one per record. An upload
      # is immutable -- editing a comment's image produces a new secret at a
      # new path -- so nothing here churns, and a file referenced twice is rare
      # enough that deduplicating across the document is all the grouping it
      # needs. Which note referred to it is recoverable by searching the file
      # for the same path.
      #
      # Runs on the filtered document, so an upload named only by a note that
      # was stripped goes with it.
      #
      # Returns nil when the document points at nothing, so the key is left out.
      def collect_uploads(document, project)
        found = {}

        each_upload(document) do |path, secret, filename|
          url = upload_url(project, path)
          found[url] ||= upload_entry(project, url, secret, filename) if url
        end

        return if found.empty?

        found.values.sort_by { |entry| entry['url'] }
      end

      # What a reader can actually fetch. The path a comment carries is not
      # that: `/uploads/<secret>/<file>` is resolved against the project when
      # the comment is rendered, by Banzai's UploadLinkFilter, which is what
      # puts the project in front of it.
      #
      # Escaped the same way the filter escapes it, so this is the URL a reader
      # would have clicked. The path as written stays a suffix of it either
      # way, so searching a document for the reference in a comment still finds
      # the entry here.
      def upload_url(project, path)
        parts = [::Gitlab.config.gitlab.relative_url_root.to_s, project.full_path, path]

        ::Addressable::URI.join(
          ::Gitlab.config.gitlab.base_url,
          ::Addressable::URI.escape(::File.join(*parts))
        ).to_s
      rescue ::Addressable::URI::InvalidURIError
        nil
      end

      def each_upload(value, &block)
        case value
        when Hash
          value.each_value { |nested| each_upload(nested, &block) }
        when Array
          value.each { |nested| each_upload(nested, &block) }
        when String
          # Upstream's own pattern, and the same call Emails::ServiceDesk and
          # Gfm::UploadsRewriter make -- an UntrustedRegexp, whose #scan yields
          # captures rather than MatchData.
          ::FileUploader::MARKDOWN_PATTERN.scan(value).each do |secret, filename|
            yield("/uploads/#{secret}/#{filename}", secret, filename)
          end
        end
      end

      # Size and checksum come from the uploads row, which the path alone
      # cannot give.
      #
      # checksum is null more often than not: Upload#needs_checksum? requires
      # local storage, so an instance keeping uploads in object storage has
      # none to report.
      def upload_entry(project, url, secret, filename)
        entry = { 'url' => url }
        record = upload_record(project, secret, filename)
        return entry unless record

        entry['size'] = record.size
        entry['checksum'] = record.checksum if record.checksum.present?
        entry
      end

      def upload_record(project, secret, filename)
        @uploads_by_path ||= {}
        key = "#{secret}/#{filename}"
        @uploads_by_path.fetch(key) { @uploads_by_path[key] = find_upload(project, secret, filename) }
      end

      # rubocop: disable CodeReuse/ActiveRecord -- the query belongs to the sync and has no finder
      def find_upload(project, secret, filename)
        ::Gitlab::PathTraversal.check_path_traversal!(filename)

        paths = ::FileUploader.new(project, secret: secret).upload_paths(filename)

        project.uploads.find_by(uploader: ::FileUploader.name, path: paths)
      rescue ::Gitlab::PathTraversal::PathTraversalAttackError, ::FileUploader::InvalidSecret
        nil
      end
      # rubocop: enable CodeReuse/ActiveRecord

      # Every confidential iid in one query per project, rather than a query
      # per reference.
      #
      # rubocop: disable CodeReuse/ActiveRecord -- the query belongs to the sync and has no finder
      def confidential_iids(project)
        @confidential_iids ||= {}
        @confidential_iids[project.id] ||= project.issues.where(confidential: true).pluck(:iid).to_set
      end
      # rubocop: enable CodeReuse/ActiveRecord

      def strip_local_ids!(value)
        case value
        when Hash
          LOCAL_ONLY_ID_KEYS.each { |key| value.delete(key) }
          value.each_value { |nested| strip_local_ids!(nested) }
        when Array
          value.each { |nested| strip_local_ids!(nested) }
        end
      end

      # Depth-first, so a map left empty by its own compaction goes too.
      def compact_blanks!(value)
        case value
        when Hash
          value.each_value { |nested| compact_blanks!(nested) }
          value.reject! { |key, nested| blank_for_export?(key, nested) }
        when Array
          value.each { |nested| compact_blanks!(nested) }
        end

        value
      end

      def blank_for_export?(key, value)
        return false if KEEP_WHEN_BLANK.include?(key)

        value.nil? || ((value.is_a?(Array) || value.is_a?(Hash)) && value.empty?)
      end

      # Has-many associations load without ORDER BY; sort them so repeated
      # serializations of unchanged records are byte-identical.
      def sort_collections!(value)
        case value
        when Hash
          value.each_value { |nested| sort_collections!(nested) }
        when Array
          value.each { |nested| sort_collections!(nested) }
          sort_hash_array!(value)
        end
      end

      def sort_hash_array!(array)
        return if array.empty? || !array.all?(Hash)

        # The export schema strips DB ids, and created_at alone can tie;
        # the serialized entry itself is the deterministic tiebreaker.
        array.sort_by! do |entry|
          [entry['created_at'].to_s, entry['iid'].to_s, ::Gitlab::Json.dump(entry)]
        end
      end
    end
  end
end
