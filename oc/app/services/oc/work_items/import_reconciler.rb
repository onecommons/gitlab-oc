# frozen_string_literal: true

module OC
  module WorkItems
    # Works out what an import run has to do, without doing any of it.
    #
    # The comparison is between two things that both describe current reality:
    # the blob oids of a peer's files on the branch, and the source_blob_oid
    # recorded on our replica rows for that peer. There is no watermark and no
    # record of how far a previous run got -- the rows are the watermark, at
    # per-file granularity.
    #
    # That is what makes every failure mode the same failure mode. A worker
    # that died, a job lost to a Sidekiq restart, a deduplicated second push, a
    # force-push, a push that triggered nothing at all: the next run sees the
    # tree as it is now and the rows as they are now, and reconciles the
    # difference. There is no "how far did I get" that can be wrong about it,
    # and no first-run special case -- no rows means everything is new.
    #
    # Deciding is deliberately separate from doing. Nothing here reads a blob's
    # contents or touches a record, so the decision table can be tested against
    # a tree and a set of rows without importing anything.
    class ImportReconciler
      include BranchTree

      KIND_BY_RELATION = { issues: :issue, merge_requests: :merge_request }.freeze

      # kind:
      #   :import  -- a path with no row of its own
      #   :rebuild -- the source file changed under a row we already have
      #   :recheck -- unchanged, but the row is deferred and may now be buildable
      #   :delete  -- a row whose source file is no longer on the branch
      Action = Struct.new(:kind, :path, :oid, :replica, :source_kind, :source_iid,
        keyword_init: true)

      def initialize(project)
        @project = project
        @repository = project.repository
      end

      # Every instance directory on the branch except our own.
      #
      # Needs no stored state: the branch is the list. Directory names are not
      # checked against a uuid shape -- a stricter filter risks silently
      # ignoring a real peer, while a loose one costs nothing, since a
      # directory holding no documents simply yields no actions.
      #
      # sha: pins the run to one view of the branch. A caller that reads
      # documents itself must pass the same sha it reads them at, or a push
      # landing mid-run pairs one commit's oids with another commit's content
      # -- and since the oid is what gets recorded, the mismatch would look
      # settled and never be revisited.
      def peer_directories(sha: nil)
        sha ||= head_sha
        return [] unless sha

        ours = OC::WorkItems.instance_directory

        @repository.tree(sha, nil, recursive: false)
          .entries
          .select { |entry| entry.type == :tree }
          .map(&:name)
          .reject { |name| name == ours }
      end

      # What to do about one peer's directory, as a list of actions. See
      # peer_directories for why sha matters.
      def plan(directory, sha: nil)
        oids = document_oids(directory, sha || head_sha)
        rows = replica_rows(directory)

        present_actions(oids, rows) + missing_actions(oids, rows)
      end

      private

      def head_sha
        @repository.commit(SYNC_BRANCH)&.sha
      end

      # Only the per-record documents. A peer's labels.yml, milestones.yml and
      # ids.yml describe their project rather than any one item, and are read
      # for context during an import rather than replicated as records.
      # commit_notes is excluded for now as well: a note on a sha we do not
      # have has nowhere sensible to live.
      def document_oids(directory, sha)
        return {} unless sha

        blob_oids_at(@repository, sha, directory).filter_map do |path, oid|
          parsed = RecordSerializer.parse_path(path)
          next unless parsed && KIND_BY_RELATION.key?(parsed[:relation])

          [path, [oid, parsed]]
        end.to_h
      end

      # rubocop: disable CodeReuse/ActiveRecord -- the query belongs to the sync and has no finder
      def replica_rows(directory)
        OC::WorkItems::ReplicatedWorkItem
          .where(project_id: @project.id, source_instance_uuid: directory)
          .index_by(&:source_path)
      end
      # rubocop: enable CodeReuse/ActiveRecord

      # Rows in a transfer's terminal states are looked up but never acted on.
      #
      # Looked up, because leaving them out of `rows` entirely would be worse
      # than acting on them: an adopted row's path is still on the branch, so
      # without a row there it reads as a file nobody has imported, and the run
      # would import the new owner's own document back as a copy of itself.
      def present_actions(oids, rows)
        oids.filter_map do |path, (oid, parsed)|
          replica = rows[path]
          next if replica && !replica.reconcilable?

          kind = kind_for(replica, oid)
          next unless kind

          Action.new(
            kind: kind, path: path, oid: oid, replica: replica,
            source_kind: KIND_BY_RELATION.fetch(parsed[:relation]),
            source_iid: parsed[:iid])
        end
      end

      def kind_for(replica, oid)
        return :import if replica.nil?
        return :rebuild if replica.source_blob_oid != oid

        # The one case where "nothing changed on the branch" does not mean
        # "nothing to do": a deferred row's source file is identical, but what
        # blocked it -- diff commits that had not arrived -- may since have
        # turned up. Skipping it on the oid alone would leave it deferred
        # forever, because nothing about the file will ever change again.
        :recheck if replica.state_deferred?
      end

      # A row whose file has gone. Deliberately not distinguished from a file
      # that went because the item became confidential: both mean the same
      # thing here, and deleting the replica is the right answer to each.
      def missing_actions(oids, rows)
        rows.filter_map do |path, replica|
          next if oids.key?(path)
          next unless replica.reconcilable?

          Action.new(kind: :delete, path: path, replica: replica,
            source_kind: replica.source_kind.to_sym, source_iid: replica.source_iid)
        end
      end
    end
  end
end
