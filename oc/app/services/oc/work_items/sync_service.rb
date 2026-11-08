# frozen_string_literal: true

module OC
  module WorkItems
    # Commits serialized work items to the sync branch.
    #
    # Every file is compared (by git blob OID) against what is already on the
    # branch; byte-identical files are skipped and a commit only happens when
    # something changed. That check is the loop terminator: our own sync push
    # re-fires MR-refresh hooks, but the second pass serializes to identical
    # bytes and produces no commit.
    class SyncService
      include BranchTree

      GC_BATCH_SIZE = 100

      IdentitiesTruncatedError = Class.new(StandardError)

      # synced_through: set by a full pass to the moment it started scanning,
      # which becomes the watermark on every commit it makes. Left nil by
      # incremental syncs, which scan nothing.
      def initialize(project, triggered_by: nil, synced_through: nil)
        @project = project
        @repository = project.repository
        @triggered_by = triggered_by
        @synced_through = synced_through
        @serializer = RecordSerializer.new
      end

      # issuables: enumerable of Issue/MergeRequest records.
      # Returns the new commit sha, or nil when nothing needed committing.
      def execute(issuables)
        return unless commit_user

        issuables = with_preloads(issuables)
        oids = branch_blob_oids
        @draft_keys = draft_keys_for(issuables)
        @existing_paths = item_paths(oids)
        actions = issuables.flat_map do |issuable|
          OC::WorkItems.syncable?(issuable) ? actions_for(issuable, oids) : []
        end

        commit!(actions + draft_actions(issuables, oids) + identities_actions(oids))
      end

      # commit_ids: enumerable of commit shas whose notes changed. Each sha's
      # file is rebuilt from whatever notes remain, and deleted once the last
      # one is gone.
      #
      # Unlike issues and merge requests, the unit here is the commit rather
      # than the record: commit notes have no iid, and the sha is the only
      # stable name available.
      def execute_commit_notes(commit_ids)
        return unless commit_user

        oids = branch_blob_oids
        actions = Array(commit_ids).uniq.filter_map do |commit_id|
          commit_notes_action_for(commit_id, oids)
        end

        commit!(actions + identities_actions(oids))
      end

      # Writes labels.yml and milestones.yml, the project's whole vocabulary
      # including everything inherited from its ancestor groups.
      #
      # Only FullSyncWorker calls this, and only on an unfiltered pass -- which
      # is also what makes it the right place to rebuild ids.yml rather than
      # add to it. By the time this runs the serializer has walked every
      # document on the branch, so the map it holds is complete and can replace
      # the committed one outright, dropping entries nothing refers to any more.
      #
      # Label and milestone edits fire no issuable hook, so there is no
      # incremental trigger to hang this off -- ReconcileWorker's nightly
      # staleness check watches the same two scopes and is what brings a rename
      # onto the branch.
      def execute_catalogs
        return unless commit_user

        oids = branch_blob_oids
        actions = catalog_records.filter_map do |key, records|
          file_action(
            RecordSerializer.catalog_file_path(key),
            @serializer.to_yaml_catalog(@project, key, records),
            oids)
        end

        # drafts.yml was written by earlier versions; nothing writes it now.
        leftover = file_action("#{OC::WorkItems.instance_directory}/drafts.yml", nil, oids)

        commit!(actions + [leftover].compact + identities_actions(oids, replace: true), create_branch: true)
      end

      # Removes drafts on the branch whose key an issue was already created
      # from -- an old copy merged back. Never recreated: the key is spent.
      def remove_drafts(paths)
        return unless commit_user

        oids = branch_blob_oids
        deletions = paths.select { |path| oids.key?(path) }.map { |path| { action: :delete, file_path: path } }
        return if deletions.empty?

        commit!(deletions)
      end

      # Removes the file for an issuable that no longer exists.
      #
      # Refuses if a record with that iid is still there, which is not the
      # belt-and-braces check it looks like. Callers arrive here having failed
      # to find a record by *id* -- and from an id's point of view "destroyed"
      # and "replaced" are the same answer. An import applies an update by
      # rebuilding: it destroys the record and creates another carrying the
      # same iid. The job queued for the destroyed one then finds nothing and
      # would delete the file belonging to the record that is now live.
      #
      # iids are unique per project and never reused, so the only way this
      # guard fires is that something deliberately recreated the record under
      # the same iid. That is precisely the case worth refusing.
      #
      # Not the path for an issuable that still exists but may no longer be
      # published -- a confidential issue on a public project. That one goes
      # through execute, where the serializer returns no content and
      # file_action turns it into the same deletion.
      def remove(issuable_type, iid)
        return unless commit_user
        return if record_exists?(issuable_type, iid)

        branch_sha = head_sha
        return unless branch_sha

        key = RecordSerializer::RELATION_KEYS.fetch(issuable_type)
        paths = item_paths(blob_oids_at(@repository, branch_sha, RecordSerializer.branch_path(key.to_s)))
          .fetch([key, iid], [])

        commit!(paths.map { |path| { action: :delete, file_path: path } })
      end

      # Deletes the sync branch outright, discarding its history.
      #
      # Committing a deletion only tombstones a file at the branch tip; the
      # content stays readable in every earlier commit. When something must
      # stop being readable -- a project that syncs confidential issues turning
      # public, or that option being switched off -- the whole branch has to
      # go. It is disposable generated output, so a FullSync rebuilds it as a
      # fresh orphan branch containing only what is now allowed.
      #
      # Note this deliberately bypasses hooks and push rules: a protected
      # branch rule covering the sync branch must not be able to block the
      # removal of content that should no longer be published. Same reasoning
      # (and same call) as the fork cleanup in OC::RepositoryForkWorker, which
      # wants the whole branch gone and calls this directly.
      #
      # Returns true when a branch was actually deleted.
      def delete_branch!
        return false unless @repository.branch_exists?(SYNC_BRANCH)

        @repository.delete_refs("refs/heads/#{SYNC_BRANCH}")
        @repository.expire_branches_cache

        true
      end

      # Unpublishes our history without unpublishing anyone else's.
      #
      # A purge exists to make our own past content unreachable, and deleting
      # the branch is the only way to do that. But since the move to
      # per-instance directories the branch is no longer only ours: it carries
      # each peer's directory, and those cannot be rebuilt from local records
      # the way ours can. Dropping them is not a delay, it is data loss --
      # the next import run reads every peer path as gone and deletes every
      # replica of every peer in the project, over a purely local
      # confidentiality toggle. A third instance importing those directories
      # from us then loses them too.
      #
      # So everything outside our own directory is carried across into the
      # fresh branch's first commit. Replaying it publishes nothing new: it is
      # the tip content the peers published themselves, and the purge is only
      # ever about our own history.
      #
      # Deliberately "everything that is not ours" rather than a list of peer
      # directories -- root-level files that are nobody's output in particular
      # are covered by the same rule, without anyone having to remember to add
      # them here.
      #
      # Returns true when a branch was actually deleted.
      def purge_own_history!
        branch_sha = head_sha
        carried = branch_sha ? foreign_files(branch_sha).merge(waiting_drafts(branch_sha)) : {}
        # The rebuild that follows (FullSyncWorker, this same instance) keeps
        # every item's name: worked out again from today's titles, a renamed
        # file would read to every peer as one item gone and another new.
        @kept_paths = branch_sha ? item_paths(branch_blob_oids).transform_values(&:first) : {}

        return false unless delete_branch!

        # One commit, not batches. Between batches the branch holds a partial
        # replay, and anything not yet written is gone -- the original was
        # deleted, and re-deriving `carried` on a retry reads the half-restored
        # branch rather than the old one. The next import run would then see
        # those paths as removed and delete every replica built from them.
        #
        # It is not a theoretical window either: the replay goes through
        # ordinary commit_files with hooks applying, and FullSyncWorker
        # swallows PreReceiveError around its whole body, so a protected-branch
        # rule biting midway is silent, immediate, partial loss that never
        # retries. The tree is already bounded by the truncation guard, so
        # there is no size argument for splitting it.
        commit!(carried.map { |path, content| { action: :create, file_path: path, content: content } }, starter: false)

        true
      end

      # Garbage collection: deletes files on the branch whose record no
      # longer exists in the database (deletions missed while sync was down,
      # or files inherited from a fork's parent). Called by FullSyncWorker
      # after the batch pass, making reconciliation fully convergent.
      def remove_orphans
        return unless commit_user

        branch_sha = head_sha
        return unless branch_sha

        orphan_paths(branch_sha).each_slice(GC_BATCH_SIZE) do |paths|
          commit!(paths.map { |path| { action: :delete, file_path: path } })
        end

        # An item with more than one file is written again rather than having
        # one picked by name: writing keeps the item's own file and deletes the
        # rest (#path_for), so a copy cannot win over the file it copied.
        duplicated_items(branch_sha).each_slice(GC_BATCH_SIZE) { |items| execute(items) }
      end

      private

      def head_commit
        @repository.commit(SYNC_BRANCH)
      end

      def head_sha
        head_commit&.sha
      end

      # {path => blob oid} for the whole branch, in one Gitaly call.
      #
      # The obvious implementation is `blob_at(sha, path)&.id` per file, but
      # that is a round-trip each -- and it ships the file's contents back just
      # so we can read the oid off the wrapper. A pass over a project with
      # thousands of work items made thousands of them, normally to conclude
      # nothing had changed.
      # Scoped to our own directory: the writer only ever compares against
      # files it wrote, and a peer's directory can be far larger than ours.
      # Safe now that BranchTree pins the path form -- entries come back rooted
      # at the repository, so these keys still match what file_action builds.
      def branch_blob_oids
        sha = head_sha
        return {} unless sha

        blob_oids_at(@repository, sha, OC::WorkItems.instance_directory)
      end

      # {path => content} for everything on the branch that this instance did
      # not write.
      #
      # blob_oids_at raises rather than returning a partial tree, which matters
      # more here than anywhere else: a truncated listing would silently leave
      # peer files out of the purge's replay, and they would be gone for good.
      #
      # load_all_data! because a blob past the display limit comes back
      # truncated, and committing that would rewrite a peer's file with a
      # prefix of itself.
      def foreign_files(branch_sha)
        ours = "#{OC::WorkItems.instance_directory}/"

        blob_oids_at(@repository, branch_sha, nil).keys.each_with_object({}) do |path, files|
          next if path.start_with?(ours)

          blob = @repository.blob_at(branch_sha, path)
          next unless blob

          blob.load_all_data!
          files[path] = blob.data
        end
      end

      # Drafts still waiting in our inbox, to survive a purge -- except a
      # confidential one, which is the kind of text a purge exists to remove,
      # and one that does not parse, whose confidentiality cannot be read.
      def waiting_drafts(branch_sha)
        directory = OC::WorkItems.instance_directory

        blob_oids_at(@repository, branch_sha, "#{directory}/#{DraftFile::DIRECTORY}").keys
          .select { |path| DraftFile.draft_path?(path, directory) }
          .each_with_object({}) do |path, drafts|
            blob = @repository.blob_at(branch_sha, path)
            blob.load_all_data!
            content = blob.data

            if DraftFile.parse(content, path: path).confidential?
              ::Gitlab::AppLogger.info(message: "work item drafts dropped by purge: #{DraftFile.key_for(path)}",
                project_id: @project.id)
              next
            end

            drafts[path] = content
          rescue DraftFile::Error
            ::Gitlab::AppLogger.info(message: "work item drafts dropped by purge: #{DraftFile.key_for(path)}",
              project_id: @project.id)
          end
      end

      # Deletes the drafts the issues in this commit were created from, in the
      # commit that publishes them as `<iid>-<key>.yml`, so the branch never
      # shows an issue without its draft gone or a draft gone without its issue.
      def draft_actions(issuables, oids)
        inbox = "#{OC::WorkItems.instance_directory}/#{DraftFile::DIRECTORY}"

        keys = issuables.grep(::Issue).filter_map { |issue| @draft_keys[issue.id] }
        paths = keys.product(DraftFile::EXTENSIONS).map { |key, extension| "#{inbox}/#{key}#{extension}" }

        paths.select { |path| oids.key?(path) }.map { |path| { action: :delete, file_path: path } }
      end

      # {issue id => draft key} for the issues among issuables made from drafts.
      # rubocop: disable CodeReuse/ActiveRecord -- the query belongs to the sync and has no finder
      def draft_keys_for(issuables)
        issue_ids = issuables.grep(::Issue).map(&:id)
        return {} if issue_ids.empty?

        OC::WorkItems::Draft.for_project(@project).where(issue_id: issue_ids).pluck(:issue_id, :key).to_h
      end
      # rubocop: enable CodeReuse/ActiveRecord

      # An item keeps the name its file already has, including one a person
      # gave it offline. A new or bare file is named from the draft key or the
      # title. Any other file for the item goes in the same commit.
      def actions_for(issuable, oids)
        content = @serializer.to_yaml(issuable)
        return [] if content == RecordSerializer::LEAVE_ALONE

        relation = @serializer.relation_key(issuable)
        existing = @existing_paths.fetch([relation, issuable.iid], [])
        path = path_for(issuable, relation, existing, content, oids)

        [file_action(path, content, oids)].compact +
          (existing - [path]).map { |other| { action: :delete, file_path: other } }
      end

      def path_for(issuable, relation, existing, content, oids)
        draft_key = @draft_keys&.dig(issuable.id) if issuable.is_a?(::Issue)
        name = RecordSerializer.item_name(issuable.title, draft_key: draft_key)
        generated = RecordSerializer.file_path(relation, issuable.iid, name)

        kept = own_file(existing, generated, content, oids) || @kept_paths&.dig([relation, issuable.iid])
        return kept if kept && named?(kept)

        name ? generated : (kept || generated)
      end

      # Of several files for one item, the one this installation was writing:
      # the file already holding what it is about to write, else the one with
      # the name it would give, else the first. A copy someone left or edited
      # then never takes the place of the file it was copied from.
      def own_file(existing, generated, content, oids)
        return existing.first if existing.size < 2

        current_oid = blob_oid(content) if content.is_a?(String)
        existing.find { |path| current_oid && oids[path] == current_oid } ||
          existing.find { |path| path == generated } || existing.first
      end

      def named?(path)
        ::File.basename(path, '.yml').include?('-')
      end

      # {[relation, iid] => [paths]} for our own item files among paths, the
      # first in sorted order being the item's file and the rest duplicates. A
      # named file sorts before a bare one (`1-a.yml` < `1.yml`).
      def item_paths(oids)
        directory = OC::WorkItems.instance_directory

        oids.keys.sort.each_with_object({}) do |path, found|
          parsed = RecordSerializer.parse_path(path)
          next unless parsed && parsed[:iid] && parsed[:directory] == directory

          (found[[parsed[:relation], parsed[:iid]]] ||= []) << path
        end
      end

      # rubocop: disable CodeReuse/ActiveRecord -- the query belongs to the sync and has no finder
      # Scoped to this project, which is what makes a moved issuable still
      # removable: it keeps its iid but leaves this project's association.
      def record_exists?(issuable_type, iid)
        key = RecordSerializer::RELATION_KEYS.fetch(issuable_type)

        @project.public_send(key).where(iid: iid).exists? # rubocop: disable GitlabSecurity/PublicSend -- the method name comes from a fixed list
      end
      # rubocop: enable CodeReuse/ActiveRecord

      # rubocop: disable CodeReuse/ActiveRecord -- the query belongs to the sync and has no finder
      def catalog_records
        {
          labels: OC::WorkItems.labels_for(@project).preload(@serializer.preloads(:labels)),
          milestones: OC::WorkItems.milestones_for(@project)
        }
      end

      def commit_notes_action_for(commit_id, oids)
        notes = @project.commit_notes.where(commit_id: commit_id)
        preloads = @serializer.commit_notes_preloads
        notes = notes.preload(preloads) if preloads

        file_action(
          RecordSerializer.commit_notes_file_path(commit_id),
          @serializer.to_yaml_commit_notes(@project, commit_id, notes),
          oids)
      end
      # rubocop: enable CodeReuse/ActiveRecord

      # ids.yml resolves the database ids the branch mentions to paths and
      # usernames. It rides along in the same commit as the documents that
      # introduced those ids, so any file on the branch can be read together
      # with the ids.yml of its own commit and get answers that were true then.
      #
      # Returns zero or one action, so it can be concatenated onto a commit
      # that may itself turn out to be empty -- writing this file is never a
      # reason to make a commit on its own.
      #
      # replace: rebuild from what this pass saw instead of adding to what is
      # already committed. Only an unfiltered pass has standing to do that.
      def identities_actions(oids, replace: false)
        fresh = @serializer.identities
        return [] if fresh.empty? && !replace

        map = replace ? fresh : merge_identities(committed_identities, fresh)
        @committed_identities = map

        [
          file_action(
            RecordSerializer.identities_file_path,
            @serializer.to_yaml_identities(map),
            oids)
        ].compact
      end

      def merge_identities(existing, fresh)
        existing.merge(fresh) { |_kind, committed, seen| committed.merge(seen) }
      end

      # What ids.yml already says. Read once per pass and then kept current in
      # memory, since this service is the only writer for its duration -- a
      # full sync commits batch by batch and would otherwise re-read the file
      # it just wrote, once per batch.
      def committed_identities
        return @committed_identities if defined?(@committed_identities)

        @committed_identities = read_identities
      end

      def read_identities
        sha = head_sha
        return {} unless sha

        blob = @repository.blob_at(sha, RecordSerializer.identities_file_path)
        return {} unless blob

        blob.load_all_data!
        # Parsing a truncated file would look like a shorter map, and writing
        # that back would drop the entries past the cut for good. Same stance
        # as check_not_truncated!: refuse a partial view rather than act on it.
        raise IdentitiesTruncatedError, "#{RecordSerializer.identities_file_path} is too large to read" if
          blob.truncated?

        RecordSerializer.parse_identities(blob.data)
      end

      # nil content means the file must not exist: the record is gone, or is no
      # longer allowed on the branch.
      def file_action(path, content, oids)
        existing_oid = oids[path]

        # A frozen item on its way to another instance: its document stays as
        # it is until the new owner's copy replaces it. Distinct from nil,
        # which means delete -- see RecordSerializer::LEAVE_ALONE.
        return if content == RecordSerializer::LEAVE_ALONE

        if content.nil?
          return { action: :delete, file_path: path } if existing_oid

          return
        end

        return if existing_oid == blob_oid(content)

        { action: existing_oid ? :update : :create, file_path: path, content: content }
      end

      # The OID git would assign this blob. Comparing OIDs rather than content
      # is what keeps this correct for files past the blob display limit, where
      # comparing truncated data would silently match. Git blob OIDs are SHA-1
      # by definition; this is not used cryptographically.
      def blob_oid(content)
        Digest::SHA1.hexdigest("blob #{content.bytesize}\0#{content}") # rubocop:disable Fips/SHA1 -- git blob oids are SHA-1
      end

      # create_branch: commit the starter files even with nothing else to
      # write. Only the full pass does, so turning sync on makes the branch.
      def commit!(actions, starter: true, create_branch: false)
        return if actions.empty? && !create_branch

        actions += starter_actions if starter && !@repository.branch_exists?(SYNC_BRANCH)
        return if actions.empty?

        options = {
          branch_name: SYNC_BRANCH,
          message: OC::WorkItems.commit_message(synced_through: watermark),
          actions: actions
        }

        if @triggered_by
          options[:author_name] = @triggered_by.name
          options[:author_email] = @triggered_by.commit_email_or_default
        end

        # When the branch doesn't exist yet this creates it as an orphan
        # (no start_branch_name/start_sha => parentless first commit).
        @repository.commit_files(commit_user, **options)
      end

      # Only in the commit that creates the branch, so a project with no work
      # items still gets one to push drafts to. Never rewritten: deleting them
      # is fine. Not drafts, so the drafts check and runs ignore them.
      def starter_actions
        inbox = "#{OC::WorkItems.instance_directory}/#{DraftFile::DIRECTORY}"

        [
          { action: :create, file_path: "#{inbox}/README.md", content: <<~MARKDOWN },
            # Issue drafts

            Add a `<key>.yml` file here and push to create an issue from it.
            Only `.yml` and `.yaml` files are drafts, so this file and
            `example.yml.sample` are ignored. To start one:

                cp example.yml.sample my-issue.yml

            See #{::Gitlab.config.gitlab.url}/help/user/project/work_items_sync/drafts.md
          MARKDOWN
          { action: :create, file_path: "#{inbox}/example.yml.sample", content: <<~YAML }
            _schema: issue_draft@1
            title: One line, at most 255 characters
            description: |
              Markdown. Write #draft:<key> to refer to another draft.
            # labels: [bug]
            # milestone: "1.0"
            # assignees: [username]
            # due_date: 2026-12-31
            # confidential: false
            # type: issue
          YAML
        ]
      end

      # What this commit should claim as the watermark. A full pass supplies
      # the moment it started scanning; an incremental sync scanned nothing, so
      # it carries forward whatever HEAD already claimed rather than advancing
      # or dropping it. Losing it would be as bad as advancing it wrongly --
      # the next reconcile would fall back to a full pass.
      def watermark
        return @synced_through if @synced_through

        OC::WorkItems.synced_through(head_commit&.message)
      end

      # The committing user must pass Gitaly push checks (Reporters who file
      # issues cannot push), so commits are performed by the project owner
      # while the acting user is preserved as git author.
      def commit_user
        @commit_user ||= @project.first_owner
      end

      # rubocop: disable CodeReuse/ActiveRecord -- the query belongs to the sync and has no finder
      # Records that have more than one file on the branch.
      def duplicated_items(branch_sha)
        files_by_relation = branch_files(branch_sha)

        { 'issues' => @project.issues, 'merge_requests' => @project.merge_requests }.flat_map do |key, relation|
          iids = (files_by_relation[key] || {}).filter_map { |iid, paths| iid if paths.size > 1 }
          iids.empty? ? [] : relation.where(iid: iids).to_a
        end
      end

      def orphan_paths(branch_sha)
        files_by_relation = branch_files(branch_sha)

        relations = {
          # MRs from/to the sync branch are unsyncable (see
          # OC::WorkItems.syncable?), so their files count as orphans too.
          'issues' => [@project.issues, :iid],
          'merge_requests' => [
            @project.merge_requests
              .where.not(source_branch: SYNC_BRANCH)
              .where.not(target_branch: SYNC_BRANCH),
            :iid
          ],
          # A commit notes file is an orphan when no note rows are left for
          # that sha -- not when the commit itself is unreachable. Notes
          # outlive a force-push, and dropping them would lose discussion the
          # database still holds.
          'commit_notes' => [@project.commit_notes, :commit_id]
        }

        relations.flat_map do |relation_key, (relation, column)|
          files = files_by_relation[relation_key]
          next [] if files.blank?

          existing = relation.where(column => files.keys).pluck(column).to_set
          # Every file of a record that is gone. A record that remains with
          # more than one file is #duplicated_items' business.
          files.flat_map { |key, paths| existing.include?(key) ? [] : paths }
        end
      end

      # Maps each relation directory on the branch to {record key => [paths]},
      # sorted, so the first is the record's own file (see #item_paths).
      # Issue/MR keys are integer iids; commit note keys are sha strings.
      #
      # Scoped to our own instance directory, and that scoping is load-bearing:
      # this is what orphan_paths walks, and a peer's documents have no local
      # record to match by construction -- so an unscoped map would have
      # remove_orphans delete every file every other instance put on the
      # branch. Their directories are not ours to collect.
      def branch_files(branch_sha)
        files_by_relation = Hash.new { |hash, key| hash[key] = {} }
        directory = OC::WorkItems.instance_directory

        @repository.ls_files(branch_sha).sort.each do |path|
          parsed = RecordSerializer.parse_path(path)
          next unless parsed && parsed[:directory] == directory

          (files_by_relation[parsed[:relation].to_s][parsed[:iid] || parsed[:commit_id]] ||= []) << path
        end

        files_by_relation
      end

      def with_preloads(issuables)
        return issuables unless issuables.is_a?(::ActiveRecord::Relation)

        key = issuables.klass <= ::MergeRequest ? :merge_requests : :issues

        # oc_replica on top of the export schema's own preloads: the serializer
        # asks every record whether it is a replica, and on a full pass that is
        # one query per issue otherwise.
        issuables.preload([@serializer.preloads(key), :oc_replica].compact)
      end
      # rubocop: enable CodeReuse/ActiveRecord
    end
  end
end
