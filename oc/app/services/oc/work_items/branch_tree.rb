# frozen_string_literal: true

module OC
  module WorkItems
    # Reading the sync branch's file listing.
    #
    # Shared by the writer and the importer so the truncation guard below
    # cannot end up applied in one and forgotten in the other -- the failure it
    # prevents is silent, and looks like a working sync doing the wrong thing.
    module BranchTree
      # Raised rather than acting on a partial view of the branch.
      TreeTruncatedError = Class.new(StandardError)

      private

      # {path => blob oid} for everything under `path`, or the whole branch
      # when it is nil, in one Gitaly call.
      #
      # The obvious implementation is `blob_at(sha, path)&.id` per file, but
      # that is a round-trip each -- and it ships the file's contents back just
      # so we can read the oid off the wrapper. A pass over a project with
      # thousands of work items made thousands of them, normally to conclude
      # nothing had changed.
      #
      # Paths come back rooted at the repository even when a subdirectory is
      # requested (Gitaly's TreeEntry carries the full path; see
      # Gitlab::GitalyClient::CommitService#tree_entries), so a scoped call and
      # an unscoped one produce keys that mean the same thing. A spec pins
      # that: if it were relative, every oid lookup against a stored path would
      # miss, and the sync would cheerfully recreate files that already exist.
      def blob_oids_at(repository, sha, path = nil)
        tree = repository.tree(sha, path, recursive: true)
        check_not_truncated!(tree)

        tree.entries.each_with_object({}) do |entry, map|
          map[entry.path] = entry.id if entry.type == :blob
        end
      end

      # GetTreeEntries caps at TREE_ENTRIES_DEFAULT_LIMIT (100_000) and says
      # nothing about it. A truncated map reads as "these files are missing",
      # which would have the sync recreate every one of them and the importer
      # delete every replica -- so refuse to act on a partial view rather than
      # guess.
      def check_not_truncated!(tree)
        return if tree.cursor&.next_cursor.blank?

        raise TreeTruncatedError, "#{SYNC_BRANCH} has more entries than one tree page"
      end
    end
  end
end
