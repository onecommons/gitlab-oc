# frozen_string_literal: true

module OC
  module WorkItems
    # One row per source file imported from a peer instance's work items sync
    # branch. Two things hang off it:
    #
    # * it is what makes a local issue or merge request a read-only replica --
    #   OC::IssuablePolicy asks for it on every permission check;
    # * it is the reconcile state. `source_blob_oid` is compared against the blob
    #   oid of the file on the branch: a path with no row is new, a differing oid
    #   means rebuild, and a row whose path has gone means delete. There is no
    #   separate watermark, so a failed or lost run leaves nothing to be
    #   inconsistent with -- the next run compares current reality on both sides.
    class ReplicatedWorkItem < ApplicationRecord
      self.table_name = 'oc_replicated_work_items'

      # Every class_name is explicitly top-level. Inside `module OC` a bare
      # `Issue` resolves to OC::Issue -- the module prepended onto the real one
      # in oc/app/models/oc/issue.rb -- and Rails infers association classes from
      # the association name in exactly that namespace. The failure is
      # `undefined method 'current_scope' for OC::Issue:Module`, and it only
      # appears when something loads the association rather than assigning it,
      # so it hides from anything that just built the record.
      belongs_to :project, class_name: '::Project'
      belongs_to :issue, class_name: '::Issue', optional: true
      belongs_to :merge_request, class_name: '::MergeRequest', optional: true

      enum :source_kind, { issue: 0, merge_request: 1 }, prefix: :source

      # imported -- the local record exists and matches source_blob_oid.
      # deferred -- nothing built yet, and `reason` says why (a merge request
      #   whose diff commits are not present locally). Re-checked on every run
      #   regardless of oid, because what blocked it may have gone away while the
      #   source file stayed exactly the same.
      # skipped  -- deliberately not imported, and never will be at this oid. A
      #   confidential document is the only case. The row exists so the nightly
      #   does not re-read and re-parse the same blob every night to reach the
      #   same conclusion.
      # errored  -- the document could not be built, and will not build at this
      #   oid however many times it is tried. Recorded so the run stops
      #   attempting it: without a state of its own, one bad file would be
      #   retried on every run forever, and while it raised, every file after it
      #   went unprocessed.
      #
      # The three below are ownership transfer, where a row stops describing a
      # copy of somebody else's item and starts describing our own. They are the
      # only states in which the row's columns do not all mean what they say
      # above, so each one's reading is spelled out:
      #
      # surrendered -- ours, frozen, on its way to somebody else. The record is
      #   the original and is read-only from the moment this row exists, whether
      #   or not the new owner has taken it yet: closing the edit window early is
      #   the point, since the window can be days long. source_instance_uuid is
      #   the *new owner's*, and source_path is *our own* old path -- the row
      #   names where the item is going, and what it is going from.
      # adopted -- somebody else's item that is now ours. The row keeps the old
      #   owner's uuid, path and oid, and is retained rather than deleted for
      #   three reasons: it is the only way back from the promoted record to the
      #   path it came from, which is what the document has to be stamped with;
      #   it is the audit of where the item came from; and it is what tells the
      #   reconcile to leave the promoted record alone.
      # matched -- the document describes an item we already have. Not built and
      #   not copied: the record is native, was here first, and stays fully
      #   editable. The row exists so that the peer's references resolve to it
      #   and the nightly stops re-reading a blob it has already accounted for.
      #   See ImportService for the identity rule (same iid, same created_at).
      enum :state, { imported: 0, deferred: 1, skipped: 2, errored: 3,
                     surrendered: 4, adopted: 5, matched: 6 }, prefix: true

      # Whether the local record is this instance's own item rather than a copy
      # of somebody else's.
      #
      # Stated in this direction on purpose. Read-only is the answer for every
      # state but two, so a state added later is read-only until somebody decides
      # otherwise -- the failure that matters here is a copy that can be edited,
      # not an item that cannot.
      def owned_here?
        state_adopted? || state_matched?
      end

      def read_only?
        !owned_here?
      end

      # Whether the generic reconcile may act on this row at all.
      #
      # The two it may not are the transfer's terminal states, and in both cases
      # the reconcile would do real damage rather than merely wasted work. An
      # adopted row's source file becomes a reference file, or goes: read as
      # drift, that is a rebuild or a delete, and both destroy an item this
      # instance now owns. A surrendered row is filed under the new owner's uuid
      # while its path names our own directory, so it can never match anything in
      # the directory being scanned -- it would look like a file that had
      # vanished, every time, and take the frozen original with it.
      def reconcilable?
        !state_surrendered? && !state_adopted?
      end

      validates :source_instance_uuid, :source_path, :source_blob_oid, :source_iid, presence: true
      validates :source_path, uniqueness: { scope: [:project_id, :source_instance_uuid] }

      scope :for_instance, ->(uuid) { where(source_instance_uuid: uuid) }

      # What the importer decided each of the source's ids means here, as
      # {kind => {local id => source id}} for the kinds ids.yml uses.
      #
      # Kept because it is the one thing about a replica that cannot be worked
      # out again from the branch. Both instances publish an ids.yml, but neither
      # says that *their* user 12 and *our* user 500 are the same person -- that
      # is a decision this instance made at import time, out of a verified email
      # or a matching username, and it is lost the moment the importer returns.
      # The reference file publishes it so a reader of the branch can line the
      # two directories up.
      def identities
        identity_map.is_a?(::Hash) ? identity_map : {}
      end

      def identities=(map)
        self.identity_map = map.presence
      end

      # Source iids this item referred to that had no local record when it was
      # built.
      #
      # Held rather than recomputed because nothing will prompt a rebuild
      # otherwise: the source file does not change when the item it points at
      # finally arrives, so the reference would stay a link to the source
      # forever. Deferred merge requests make that the ordinary case, not a
      # corner -- a deferred item builds in a later run than whatever referred
      # to it, by definition.
      def unresolved
        unresolved_refs.is_a?(::Array) ? unresolved_refs.map(&:to_i) : []
      end

      def unresolved=(iids)
        self.unresolved_refs = ::Array.wrap(iids).map(&:to_i).uniq.sort.presence
      end

      scope :with_unresolved, -> { where.not(unresolved_refs: nil) }

      # The local record, whichever kind this row describes. Nil while deferred,
      # and nil again if the replica was destroyed -- the foreign keys nullify
      # rather than cascade, so the row outlives a rebuild.
      def work_item
        source_issue? ? issue : merge_request
      end

      def work_item=(record)
        case record
        when ::MergeRequest then self.merge_request = record
        when ::Issue then self.issue = record
        else raise ArgumentError, "not a work item: #{record.class}"
        end
      end
    end
  end
end
