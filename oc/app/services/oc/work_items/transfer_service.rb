# frozen_string_literal: true

module OC
  module WorkItems
    # Carries out what TransferReconciler decided.
    #
    # Ownership is already expressed by the branch: whoever holds an item's
    # document owns it, and everyone else holds a reference file where that
    # document would go. A transfer swaps the two, with a window in between
    # where the old owner has stopped editing and the new one has not started.
    #
    # Nothing here talks to the other instance. Each side acts on its own copy
    # of the branch when its own push arrives, and the states are chosen so
    # that either order converges.
    class TransferService
      def initialize(project)
        @project = project
      end

      # Stops this instance editing an item, because it has been promised to
      # another one. Does not wait for the other instance to take it, and
      # cannot: the two pushes may be days apart, and an edit made here in
      # between would be silently superseded. Closing the window early is why
      # this is a state of its own rather than one step run when the new
      # owner's document arrives.
      def freeze_for_transfer(decision)
        record = local_record(decision)
        return refuse(decision, 'there is no such issue here') unless record

        # Never transferable, and the other side refuses them too, so neither
        # instance ends up waiting on the other for ever.
        return refuse(decision, 'confidential issues are not transferable') if record.confidential?

        existing = record.oc_replica
        return refuse(decision, refusal_for(existing)) if existing && !existing.state_surrendered?
        return if existing

        surrender(decision, record)
      end

      # Takes an item another instance promised us. Nothing is built: the
      # document was already imported, and this changes what the row says the
      # copy is. The serializer then publishes the item where its pointer was,
      # which tells the old owner it may let go.
      #
      # document: the parsed YAML at decision.path.
      def promote(decision, document)
        replica = decision.replica
        return refuse(decision, 'it has not been imported here yet') unless replica

        # The other half of the ratchet. Without it, two instances that both
        # declare `transfer: all` each take every item straight back and both
        # end up owning it. An item somebody was given can never be given away
        # again, so no promotion of one is legitimate.
        return refuse(decision, 'it reached that instance from a third one') if
          document['transferred_from'].present?

        case replica.state.to_sym
        when :adopted then nil
        when :imported, :matched then adopt(decision, replica)
        else refuse(decision, "it is #{replica.state} here")
        end
      end

      private

      # rubocop: disable CodeReuse/ActiveRecord -- the query belongs to the sync and has no finder
      def local_record(decision)
        @project.issues.find_by(iid: decision.source_iid)
      end
      # rubocop: enable CodeReuse/ActiveRecord

      # Read off the record, never looked up by the declared path: an adopted
      # row is keyed by the path the item came *from*, so a path-keyed check
      # finds nothing and hands back an item we were given.
      def refusal_for(replica)
        case replica.state.to_sym
        when :adopted
          'it was transferred here, and a transfer is not reversible'
        when :matched
          'it is also held by another instance, which has to be settled first'
        else
          'it belongs to another instance -- this is a copy of it'
        end
      end

      def surrender(decision, record)
        OC::WorkItems::ReplicatedWorkItem.create!(
          project: @project,
          # The instance it is going to, not one it came from. A surrendered
          # row is the only one that reads forwards.
          source_instance_uuid: decision.peer,
          source_path: decision.path,
          source_kind: :issue,
          source_iid: decision.source_iid,
          source_blob_oid: decision.oid,
          state: :surrendered,
          work_item: record)
      rescue ::ActiveRecord::RecordNotUnique
        # Another run froze it between our decision and our insert. Already
        # done, and ours has nothing to add.
        nil
      end

      # imported and matched arrive from opposite directions and leave the same
      # way; neither needs the record touched.
      def adopt(decision, replica)
        record = replica.work_item
        return refuse(decision, 'it has no local record') unless record

        # A rebuild or delete planned by a concurrent run against the state this
        # row is leaving would destroy the record. Checking inside the
        # transaction makes either order converge.
        return unless claim(replica)

        # A matched item never went through the importer, so nothing turned sync
        # on -- and without it the document is never published and the giver
        # waits frozen for ever.
        start_syncing

        OC::WorkItems.enqueue_sync(record)

        replica
      end

      # rubocop: disable CodeReuse/ActiveRecord -- the query belongs to the sync and has no finder
      def claim(replica)
        ::ApplicationRecord.transaction do
          fresh = OC::WorkItems::ReplicatedWorkItem.lock.find_by(id: replica.id)
          next false unless fresh
          next false unless fresh.state == replica.state
          next false unless fresh.source_blob_oid == replica.source_blob_oid

          # A promoted item is no longer machine-rebuilt, so a list of
          # references it was still waiting for would sit there meaning
          # nothing.
          fresh.update!(state: :adopted, unresolved: nil)
          replica.reset

          true
        end
      end
      # rubocop: enable CodeReuse/ActiveRecord

      # See ImportService for why a project holding replicas has to sync.
      def start_syncing
        return if @project.work_items_sync_enabled?

        @project.enable_work_items_sync!(true)
      end

      def refuse(decision, reason)
        ::Gitlab::AppLogger.info(
          message: 'work items transfer refused',
          project_id: @project.id, path: decision.path, peer: decision.peer, reason: reason)

        nil
      end
    end
  end
end
