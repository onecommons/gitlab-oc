# frozen_string_literal: true

module OC
  module WorkItems
    # One import run: reads what the branch says now, and makes the local
    # replicas agree with it.
    #
    # The pieces either side of this have been buildable on their own --
    # ImportReconciler decides what to do without doing it, ImportService does
    # one file without deciding anything. This is what joins them, and it is
    # also where the two things neither of them can see get handled: reading
    # the documents off the branch, and the fact that items refer to each
    # other.
    class ImportRunService
      include BranchTree

      # Which peers to reconcile is the caller's to decide, and the decision is
      # an authorization one -- see #execute.
      def initialize(project)
        @project = project
        @repository = project.repository
        @reconciler = ImportReconciler.new(project)
      end

      # directories: which peers to reconcile, nil for every peer sync.yml
      # declares an import from.
      #
      # Required, with no default, because nil is the widest scope there is and
      # nobody should reach it by leaving an argument off. A push-triggered run
      # asks for it deliberately: an Owner pushed the branch and that is the
      # gate. The nightly passes only the peers that already have replica rows,
      # so it heals and extends imports that were once authorized and never
      # makes first contact -- without which it would be a way around the Owner
      # check, push as a Developer, be correctly refused, and have the cron do
      # it a few hours later.
      #
      # Both are then intersected with what the branch's sync.yml declares, so
      # the widest scope is still only the peers somebody wrote down. The Owner
      # check says the reading is authorized; the file says which peers were
      # meant. Neither answers the other's question.
      # initiate_transfers: whether this run may start a transfer -- freeze one
      # of our items because the branch says it has been promised away, or take
      # one promised to us.
      #
      # False by default, and the default is the important part. Only a
      # push-triggered run passes true, because only there is there somebody to
      # have authorized it: an Owner pushed the branch. The nightly has no
      # pusher, and the bound it runs under -- peers we already hold rows for
      # -- authorizes replicating those peers, not accepting an item from them.
      # Rows from ordinary replication already exist, so without this a
      # Developer could push a declaration, have the import correctly refuse
      # it, and have the cron carry it out a few hours later.
      #
      # Finishing a transfer already under way is a different matter and is not
      # gated: a demote needs a surrendered row, and that row is itself the
      # record that an authorized run started this.
      def execute(directories:, initiate_transfers: false)
        # One view of the branch for the whole run, read once and passed
        # everywhere. Not memoized across runs: a service instance outlives a
        # push, and a stale sha would have the reconciler plan against the new
        # tip while the documents were read from the old one -- importing
        # yesterday's content and recording today's oid, which then looks
        # settled and is never revisited.
        @head_sha = @repository.commit(SYNC_BRANCH)&.sha

        # No branch is an absence, not an instruction. It could equally be a
        # branch nobody has pushed yet or one being replaced mid-purge, and
        # neither means "drop every replica". A directory removed from a branch
        # that is still there is a deliberate edit, and does mean that.
        return if @head_sha.nil?

        @sync_file = SyncFile.load(read_blob(SyncFile::PATH), project: @project)

        # Freeze first, so that a single push carrying both the declaration and
        # the new owner's document can freeze and then finish in one run.
        freeze_promised if initiate_transfers

        pairs = @sync_file.imports(OC::WorkItems.instance_directory)
        pairs = pairs.slice(*directories) if directories

        pairs.each do |directory, pair|
          import(directory, pair)
        end

        demote_only(pairs.keys, directories)

        # Promote last, so that a document imported earlier in this same run
        # can be taken in it.
        take_promised if initiate_transfers
      end

      private

      def transfers
        @transfers ||= TransferReconciler.new(@project, @sync_file)
      end

      def transfer_service
        @transfer_service ||= TransferService.new(@project)
      end

      def freeze_promised
        transfers.freezes(sha: @head_sha).each do |decision|
          transfer_service.freeze_for_transfer(decision)
        end
      end

      # Planned after the import phase rather than beside the freezes, because
      # what a promotion needs is the row -- and the run may have made it a
      # moment ago.
      def take_promised
        transfers.promotions(sha: @head_sha).each do |decision|
          document = read_document(decision.path)
          next unless document

          transfer_service.promote(decision, document)
        end
      end

      # The one deliberate exception to importing only what is declared.
      #
      # An instance giving items away and taking none -- the shape of a
      # migration, and what the docs recommend for one -- declares no import at
      # all. It still has to read the directory its items went to, twice over:
      # to let go of them in the first place, since a freeze that cannot
      # complete is permanent, and afterwards to keep the copies it is left
      # with tracking their new owner's edits.
      #
      # So a directory nobody declared is read when this instance holds any row
      # for it, and only documents stamped as having come from *our* directory
      # are acted on. That stamp is what separates this from an import
      # declaration somebody withdrew: a peer we merely used to mirror has
      # never been given anything, so nothing of theirs carries our mark and
      # nothing of theirs is touched -- which is what withdrawing was supposed
      # to mean.
      #
      # Not a way around the gating either. Acting on a stamp requires either a
      # promise this instance made -- a row only an Owner-authorized run
      # writes -- or a copy we already hold, so a peer cannot get anything to
      # happen by writing a stamp. And it is nearly free: the plan only
      # produces actions for files that changed, so a settled directory is a
      # tree read and nothing else.
      def demote_only(imported, directories)
        pending = recorded_directories - imported
        pending &= directories if directories

        pending.each do |directory|
          import(directory, undeclared_pair(directory), demote_only: true)
        end
      end

      # rubocop: disable CodeReuse/ActiveRecord -- the query belongs to the sync and has no finder
      def recorded_directories
        OC::WorkItems::ReplicatedWorkItem
          .where(project_id: @project.id)
          .distinct
          .pluck(:source_instance_uuid)
      end
      # rubocop: enable CodeReuse/ActiveRecord

      # There is no declaration to read settings off, so the defaults apply.
      # For identity mapping that is the useful answer rather than merely a
      # safe one: these documents are our own items coming home, and the people
      # in them are our own people.
      def undeclared_pair(directory)
        SyncFile::Pair.new(peer_name: directory, peer_uuid: directory)
      end

      # A peer no declaration names is not visited at all -- not to update it,
      # and not to delete what we hold of it either. Withdrawing an import says
      # "stop mirroring this peer", not "throw away what you mirrored"; removing
      # the directory from the branch remains the one thing that means the
      # second. A peer that is still declared *is* visited even when nothing of
      # theirs is on the branch any more, which is what keeps a pruned directory
      # deleting its replicas.
      def import(directory, pair, demote_only: false)
        default_user = default_user_for(pair)
        return if default_user == :unsatisfied

        service = ImportService.new(
          @project,
          source_instance_uuid: directory,
          identities: peer_identities(directory),
          trust: pair.trust,
          default_user: default_user)

        actions = @reconciler.plan(directory, sha: @head_sha)
        actions = actions.select { |action| transferred?(directory, action.path) } if
          pair.imports_transferred?

        actions.each do |action|
          if demote_only
            # Deletes are left alone: an item that was ours, that we handed
            # over, is not something to drop here because the instance holding
            # it deleted their copy. Removing the directory remains the way to
            # say that, as everywhere else.
            apply(service, action, only: method(:ours_to_finish?)) unless action.kind == :delete
          else
            action.kind == :delete ? remove(action) : apply(service, action)
          end
        end

        rebuild_now_resolvable(service, directory, pair) unless demote_only
      end

      # In a directory nobody declared, the one thing a document can be that
      # this instance has any business acting on: one carrying our own mark,
      # for an item we either promised away or already hold.
      #
      # Both halves matter. The mark alone is peer-written and proves nothing;
      # the promise and the copy are ours, and one of them has to be there or
      # this is an instance claiming something we never agreed to.
      #
      # rubocop: disable CodeReuse/ActiveRecord -- the query belongs to the sync and has no finder
      def ours_to_finish?(action, document)
        stamp = document['transferred_from']
        return false unless stamp.present?
        return false unless stamp.start_with?("#{OC::WorkItems.instance_directory}/")

        action.replica.present? ||
          OC::WorkItems::ReplicatedWorkItem.exists?(
            project_id: @project.id, source_path: stamp, state: :surrendered)
      end
      # rubocop: enable CodeReuse/ActiveRecord

      # Who an unmapped user on the peer becomes here.
      #
      # nil is the ghost user, which is both the default and what <ghost> asks
      # for explicitly. :unsatisfied means the pair named an account we cannot
      # use, and the whole pair waits: importing the peer's items attributed to
      # somebody other than the account that was asked for would be worse than
      # importing them later, and the declaration can become satisfiable at any
      # time by creating the account or adding it to the project.
      #
      # Membership is a policy of ours, not a rule of GitLab's -- nothing about
      # an author or an assignee requires it at the model layer. It is here so
      # that an Owner editing a file on a shared branch cannot make an
      # unaffiliated local account the author and assignee of a peer's content.
      # Bots and service accounts pass, and are what the docs recommend.
      def default_user_for(pair)
        return if pair.default_user_ghost?

        user = ::User.find_by_username(pair.default_user)
        return unsatisfied(pair, 'no such user') unless user

        # admin? rather than can_admin_all_resources?, which the cop below
        # would rather have: that one is `admin? && admin_mode?`, and admin
        # mode is a property of a browser session. This account is not signed
        # in -- it is a name in a file, being asked about by a background job --
        # so the admin-mode form is false for every account there has ever
        # been, and the rule would be dead code that reads as though it works.
        # The question here is what standing the named account has, not what it
        # is allowed to do right now.
        #
        # rubocop: disable Cop/UserAdmin -- standing, not current admin mode, is the question
        allowed = @project.team.member?(user) || user.admin?
        # rubocop: enable Cop/UserAdmin

        return user if allowed

        unsatisfied(pair, 'the user is not a member of this project')
      end

      def unsatisfied(pair, reason)
        ::Gitlab::AppLogger.info(
          message: 'work items import waiting: default_user cannot be used',
          project_id: @project.id, peer: pair.peer_uuid,
          default_user: pair.default_user, reason: reason)

        :unsatisfied
      end

      # Under `import: transferred` we replicate only what the peer currently
      # gives us, rather than their whole directory -- the containment answer
      # for a peer whose items we mostly already have.
      #
      # Filtering the actions rather than the tree means it applies to a row
      # whose file has gone as well as to a file we have no row for. That
      # matters: without it, every row outside the transfer set would look like
      # a file that had vanished, and the run would delete replicas nobody
      # asked it to.
      def transferred?(directory, path)
        giving = @sync_file.transfers_to(OC::WorkItems.instance_directory)[directory]
        return false unless giving
        return path.start_with?("#{directory}/issues/") if giving.transfers_all?

        giving.transfer.any? { |relative| path == "#{directory}/#{relative}" }
      end

      # One document is allowed to fail, and only that document.
      #
      # Anything raising here would otherwise abandon the rest of the run --
      # every remaining file, and every directory after this one -- and do it
      # again on every retry, since the same bytes fail the same way. Version
      # drift between builds is enough to produce a document that parses and
      # will not build.
      # only: a predicate on the parsed document. Applied here rather than
      # before the loop so that a scan which has to read documents to know
      # which ones concern it reads each of them once.
      def apply(service, action, only: nil)
        document = read_document(action.path)

        if document.nil?
          # Not ours to record when we are only passing through: a scan that
          # was never asked to mirror this directory has no business leaving
          # rows about the state of its files.
          service.record_failure(action, nil, 'the document could not be read as YAML') unless only
          return
        end

        return if only && !only.call(action, document)

        service.import(action, document)
      rescue ::ActiveRecord::RecordNotUnique
        # Another run imported this file between our plan and our insert. It is
        # done, and ours has nothing to add -- the unique index doing exactly
        # the job it is there for.
        nil
      rescue ::StandardError => error
        ::Gitlab::AppLogger.warn(
          message: 'work items import could not build a document',
          project_id: @project.id, path: action.path,
          error_class: error.class.name, error: error.message)

        service.record_failure(action, document['web_url'], error.message)
      end

      # Items refer to each other, and a run builds them in some order, so the
      # first cannot see the second -- and they can name each other in a
      # circle, which no ordering fixes. Worse, a deferred item is built in a
      # later run than whatever referred to it, by definition.
      #
      # So each item records what it wanted and could not find, and anything
      # whose wants have since arrived is built again. Reading that back from
      # the rows rather than from this run's memory is what makes it work
      # across runs as well as within one.
      #
      # Only when something it wanted has actually appeared: otherwise a
      # project whose items point at things nobody has imported would rebuild
      # every one of them on every run, for ever.
      def rebuild_now_resolvable(service, directory, pair)
        rows_awaiting(directory).each do |row|
          next if pair.imports_transferred? && !transferred?(directory, row.source_path)
          next unless row.unresolved.any? { |iid| resolvable?(directory, iid) }

          document = read_document(row.source_path)
          next unless document

          apply(service, rebuild_of(row))
        end
      end

      # rubocop: disable CodeReuse/ActiveRecord -- the query belongs to the sync and has no finder
      def rows_awaiting(directory)
        OC::WorkItems::ReplicatedWorkItem
          .where(project_id: @project.id, source_instance_uuid: directory)
          .state_imported
          .with_unresolved
      end
      # rubocop: enable CodeReuse/ActiveRecord

      def rebuild_of(row)
        ImportReconciler::Action.new(
          kind: :rebuild, path: row.source_path, oid: row.source_blob_oid, replica: row,
          source_kind: row.source_kind.to_sym, source_iid: row.source_iid)
      end

      # Both relations, because an unresolved reference is recorded as a bare
      # number -- `#5` and `!5` are indistinguishable by then. Being generous
      # here costs a rebuild that changes nothing; being strict would miss one
      # that mattered.
      #
      # rubocop: disable CodeReuse/ActiveRecord -- the query belongs to the sync and has no finder
      def resolvable?(directory, source_iid)
        %w[issues merge_requests].any? do |relation|
          OC::WorkItems::ReplicatedWorkItem.find_by(
            project_id: @project.id,
            source_instance_uuid: directory,
            source_path: "#{directory}/#{relation}/#{source_iid}.yml")&.work_item.present?
        end
      end
      # rubocop: enable CodeReuse/ActiveRecord

      # The row goes with the record. Leaving it would be worse than either:
      # the reconcile would see a path it has no row for and import the item
      # again on the next run.
      #
      # Except for a matched row, where the record is not ours to delete. It
      # was here before the peer's file was, and the row only ever said the two
      # describe the same item; the peer deleting their copy says nothing about
      # ours. Dropping the row alone is the whole of it -- and if their file
      # comes back, the identity check simply matches it again.
      #
      # Refuses to act on a row that has changed since the plan was made, for
      # the reason ImportService#unchanged? explains: a row that was a copy
      # then can be an item this instance owns now, and this is the path that
      # destroys it.
      #
      # rubocop: disable CodeReuse/ActiveRecord -- the query belongs to the sync and has no finder
      def remove(action)
        OC::WorkItems.suppress_sync do
          ::ApplicationRecord.transaction do
            fresh = OC::WorkItems::ReplicatedWorkItem.lock.find_by(id: action.replica.id)
            next unless fresh
            next unless fresh.state == action.replica.state
            next unless fresh.source_blob_oid == action.replica.source_blob_oid

            fresh.work_item&.destroy! unless fresh.state_matched?
            fresh.destroy!
          end
        end
      end
      # rubocop: enable CodeReuse/ActiveRecord

      def peer_identities(directory)
        yaml = read_blob("#{directory}/#{RecordSerializer::IDENTITIES_KEY}.yml")
        return {} if yaml.blank?

        RecordSerializer.parse_identities(yaml)
      end

      # A document that will not parse is skipped rather than raised on: one
      # unreadable file on a peer's branch should not stop every other item in
      # the run from being imported.
      def read_document(path)
        yaml = read_blob(path)
        return if yaml.blank?

        parsed = ::YAML.safe_load(yaml, permitted_classes: [::Date, ::Time])
        parsed if parsed.is_a?(::Hash)
      rescue ::Psych::Exception => error
        ::Gitlab::AppLogger.warn(
          message: 'work items import skipped an unreadable document',
          project_id: @project.id, path: path, error: error.message)
        nil
      end

      def read_blob(path)
        blob = @repository.blob_at(@head_sha, path)
        return unless blob

        blob.load_all_data!
        blob.data
      end
    end
  end
end
