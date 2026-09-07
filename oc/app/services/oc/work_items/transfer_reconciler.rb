# frozen_string_literal: true

module OC
  module WorkItems
    # What the branch is asking this instance to hand over, and what it is
    # being handed. Decides; does none of it.
    #
    # Separate from ImportReconciler because that one asks what has changed and
    # this one asks what somebody intends. A declaration never goes stale the
    # way an oid does, so re-reading a satisfied one has to be harmless; the
    # guards that make it so live on the doing side.
    #
    # `transfer: all` expands against the branch rather than the database: an
    # item never written there cannot be handed over, because freezing it would
    # stop it ever being published. One filed after the declaration landed
    # therefore takes two runs, which is the right order.
    class TransferReconciler
      include BranchTree

      # kind:
      #   :freeze  -- one of ours, promised to `peer`. `path` is in our own
      #               directory.
      #   :promote -- one of theirs, promised to us. `path` is in `peer`'s
      #               directory, and `replica` is the row we hold for it, if
      #               any: nil means the document has not been imported, and
      #               the promise waits rather than failing.
      #
      # oid is the blob at `path` when the decision was taken, which is what a
      # freeze records as the version of our document it froze.
      Decision = Struct.new(:kind, :peer, :path, :source_iid, :oid, :replica, keyword_init: true)

      def initialize(project, sync_file)
        @project = project
        @sync_file = sync_file
        @repository = project.repository
      end

      # Items this instance has promised away.
      def freezes(sha:)
        decisions(sha, @sync_file.transfers_from(us)) do |peer, path, iid, oid|
          Decision.new(kind: :freeze, peer: peer, path: path, source_iid: iid, oid: oid)
        end
      end

      # Items promised to this instance.
      #
      # Read out of the giving instances' blocks: a transfer is declared by the
      # side losing the item, so a receiver never finds one under its own name.
      def promotions(sha:)
        rows = nil

        decisions(sha, @sync_file.transfers_to(us), own: false) do |peer, path, iid, oid|
          rows ||= replica_rows
          Decision.new(kind: :promote, peer: peer, path: path, source_iid: iid, oid: oid,
            replica: rows[path])
        end
      end

      private

      def us
        OC::WorkItems.instance_directory
      end

      # own: whose directory the promised paths are relative to. A transfer
      # names paths in the giver's directory, so it is ours when we are giving
      # and theirs when we are receiving.
      def decisions(sha, pairs, own: true)
        return [] if sha.nil? || pairs.empty?

        pairs.flat_map do |peer, pair|
          directory = own ? us : peer
          oids = issue_oids(directory, sha)

          pair.transfer_paths(oids.keys).filter_map do |relative|
            # A named path the branch does not carry is not a mistake to
            # report, it is one to wait for -- an item filed after the
            # declaration was written, whose document the next sync will
            # publish. Acting now would freeze it before it was ever
            # published, and the instance waiting for it would wait for good.
            next unless oids.key?(relative)

            path = "#{directory}/#{relative}"
            parsed = RecordSerializer.parse_path(path)
            next unless parsed

            yield(peer, path, parsed[:iid], oids[relative])
          end
        end
      end

      # {relative path => blob oid} for the issue documents in a directory.
      # Relative, because that is the form a transfer list is written in.
      #
      # Reference files are in here too, and deliberately: `transfer: all`
      # sweeping up items we only mirror is not something to filter out
      # quietly, because the two are indistinguishable by path and telling
      # them apart needs the row. The freeze refuses them, and says so.
      def issue_oids(directory, sha)
        blob_oids_at(@repository, sha, directory).filter_map do |path, oid|
          parsed = RecordSerializer.parse_path(path)
          next unless parsed && parsed[:relation] == :issues

          [path.delete_prefix("#{directory}/"), oid]
        end.to_h
      end

      # rubocop: disable CodeReuse/ActiveRecord -- the query belongs to the sync and has no finder
      def replica_rows
        OC::WorkItems::ReplicatedWorkItem
          .where(project_id: @project.id)
          .index_by(&:source_path)
      end
      # rubocop: enable CodeReuse/ActiveRecord
    end
  end
end
