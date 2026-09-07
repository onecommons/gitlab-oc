# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../support/helpers/work_item_sync_paths'

RSpec.describe OC::WorkItems::ImportRunService, feature_category: :source_code_management do
  # Pins this instance's uuid, which peer_directories compares against to work
  # out which directories are somebody else's.
  include WorkItemSyncPaths

  # let, not let_it_be: the repository is Gitaly state and does not roll back
  # with the database, so a shared project carries one example's seeded files
  # into the next. Sharing one and deleting the branch between examples was
  # tried and does not work -- something survives the reset that should not,
  # and a spec that lies is worse than a slow one.
  let(:project) { create(:project, :repository) }
  let(:peer) { '11111111-2222-3333-4444-555555555555' }
  let(:branch) { OC::WorkItems::SYNC_BRANCH }
  let(:service) { described_class.new(project) }

  def seed(path, content)
    project.repository.create_file(
      project.first_owner, path, content, message: 'peer push', branch_name: branch)
  end

  def write(path, content)
    if project.repository.blob_at(branch, path)
      project.repository.update_file(
        project.first_owner, path, content, message: 'peer push', branch_name: branch)
    else
      seed(path, content)
    end
  end

  # Importing is opt-in per relationship, so an example that expects anything
  # to be imported has to declare it. Peers are named p0, p1... in the file;
  # the names are branch-local and only the uuids mean anything.
  def declare(*peers, **pair_keys)
    blocks = peers.each_with_index.map { |uuid, index| "p#{index}:\n  uuid: #{uuid}\n" }
    directives = pair_keys.map { |key, value| "      #{key}: #{value}\n" }.join
    syncs = peers.each_index.map { |index| "    p#{index}:\n      import: all\n#{directives}" }

    write(OC::WorkItems::SyncFile::PATH, <<~YAML)
      ---
      _schema: sync@1
      #{blocks.join}us:
        uuid: #{OC::WorkItems.instance_directory}
        sync:
      #{syncs.join}
    YAML
  end

  def document(iid:, title: 'Imported', description: 'body')
    <<~YAML
      ---
      _schema: issues@1
      title: #{title}
      description: #{description.to_json}
      author_id: 12
      project_id: 99
      iid: #{iid}
      state: opened
      confidential: false
      created_at: '2026-03-14T09:00:00.000Z'
      updated_at: '2026-03-14T09:00:00.000Z'
      web_url: https://peer.example.com/group/project/-/issues/#{iid}
    YAML
  end

  def seed_ids
    seed("#{peer}/#{OC::WorkItems::RecordSerializer::IDENTITIES_KEY}.yml", <<~YAML)
      ---
      _schema: ids@1
      projects:
        99: group/project
      users:
        12:
          username: remote-author
          name: Remote Author
    YAML
  end

  def replicas
    OC::WorkItems::ReplicatedWorkItem.where(project_id: project.id)
  end

  # The push path: every peer directory on the branch. #execute has no default
  # for this, so that nobody reaches the widest scope by leaving an argument
  # off -- which means saying it here, once, rather than at thirty call sites.
  def run_all
    service.execute(directories: nil)
  end

  describe '#execute' do
    before do
      declare(peer)
    end

    it 'does nothing when the branch has no peer directories' do
      expect { run_all }.not_to change { OC::WorkItems::ReplicatedWorkItem.count }
    end

    it 'imports every document in a peer directory' do
      seed_ids
      seed("#{peer}/issues/1.yml", document(iid: 1, title: 'First'))
      seed("#{peer}/issues/2.yml", document(iid: 2, title: 'Second'))

      run_all

      expect(replicas.count).to eq(2)
      expect(project.issues.map(&:title)).to contain_exactly('First', 'Second')
    end

    it 'reads the peer ids.yml, so the byline names the original author' do
      seed_ids
      seed("#{peer}/issues/1.yml", document(iid: 1))

      run_all

      expect(project.issues.first.description).to include('*By Remote Author')
    end

    it 'is idempotent -- a second run with an unchanged branch changes nothing' do
      seed_ids
      seed("#{peer}/issues/1.yml", document(iid: 1))
      run_all
      issue_id = replicas.first.issue_id

      expect { run_all }.not_to change { OC::WorkItems::ReplicatedWorkItem.count }
      expect(replicas.first.issue_id).to eq(issue_id)
    end

    it 'rebuilds an item whose source file changed' do
      seed_ids
      seed("#{peer}/issues/1.yml", document(iid: 1, title: 'Before'))
      run_all

      project.repository.update_file(
        project.first_owner, "#{peer}/issues/1.yml", document(iid: 1, title: 'After'),
        message: 'peer push', branch_name: branch)
      run_all

      expect(project.issues.reload.map(&:title)).to contain_exactly('After')
    end

    it 'destroys a replica whose source file is gone, and its row with it' do
      seed_ids
      seed("#{peer}/issues/1.yml", document(iid: 1))
      run_all

      project.repository.delete_file(
        project.first_owner, "#{peer}/issues/1.yml", message: 'peer push', branch_name: branch)
      run_all

      expect(replicas.count).to eq(0)
      expect(project.issues.reload).to be_empty
    end

    # Items refer to each other, and a run builds them in some order, so the
    # first cannot see the second. They can even refer to each other in a
    # circle, which no ordering fixes.
    describe 'items that refer to each other' do
      before do
        seed_ids
        seed("#{peer}/issues/1.yml", document(iid: 1, description: 'blocked by #2'))
        seed("#{peer}/issues/2.yml", document(iid: 2, description: 'blocks #1'))
      end

      it 'resolves both directions once the run is complete' do
        run_all

        first = project.issues.find_by(iid: 1)
        second = project.issues.find_by(iid: 2)

        expect(first.description).to include("blocked by ##{second.iid}")
        expect(second.description).to include("blocks ##{first.iid}")
      end

      # The case in-run memory could not cover: the referenced item does not
      # arrive until a later run. A deferred merge request makes this the
      # ordinary shape, not a corner -- it is built in a later run than
      # whatever referred to it, by definition.
      it 'resolves a reference once the item it names arrives in a later run' do
        project.repository.delete_file(
          project.first_owner, "#{peer}/issues/2.yml", message: 'not yet', branch_name: branch)

        run_all

        first = project.issues.find_by(iid: 1)
        expect(first.description).to include('[#2](https://peer.example.com')
        expect(replicas.find_by(source_iid: 1).unresolved).to eq([2])

        seed("#{peer}/issues/2.yml", document(iid: 2, description: 'blocks #1'))
        run_all

        # Re-fetched by iid rather than reloaded: a rebuild replaces the
        # record, so the object from before the second run no longer exists.
        second = project.issues.find_by(iid: 2)
        rebuilt = project.issues.find_by(iid: 1)

        expect(rebuilt.id).not_to eq(first.id)
        expect(rebuilt.description).to include("blocked by ##{second.iid}")
        expect(replicas.find_by(source_iid: 1).unresolved).to be_empty
      end

      # Otherwise a project whose items point at things nobody has imported
      # would rebuild every one of them on every run, forever.
      it 'does not rebuild anything on a second run' do
        run_all
        ids = project.issues.reload.map(&:id).sort

        run_all

        expect(project.issues.reload.map(&:id).sort).to eq(ids)
      end
    end

    it 'still links to the source when the referenced item is nowhere on the branch' do
      seed_ids
      seed("#{peer}/issues/1.yml", document(iid: 1, description: 'blocked by #99'))

      run_all

      expect(project.issues.first.description).to include(
        '[#99](https://peer.example.com/group/project/-/issues/99)')
    end

    # No history is walked -- the reconcile compares the tree to the rows --
    # so a branch replaced wholesale is just a branch that looks different.
    it 'converges after a force-push that shares no history' do
      seed_ids
      seed("#{peer}/issues/1.yml", document(iid: 1, title: 'Before'))
      run_all

      project.repository.delete_refs("refs/heads/#{branch}")
      project.repository.expire_branches_cache
      declare(peer)
      seed_ids
      seed("#{peer}/issues/1.yml", document(iid: 1, title: 'After'))

      run_all

      expect(project.issues.reload.map(&:title)).to contain_exactly('After')
      expect(replicas.count).to eq(1)
    end

    it 'imports afresh when a file is deleted and later restored' do
      seed_ids
      seed("#{peer}/issues/1.yml", document(iid: 1))
      run_all
      first_id = replicas.first.issue_id

      project.repository.delete_file(
        project.first_owner, "#{peer}/issues/1.yml", message: 'gone', branch_name: branch)
      run_all
      expect(replicas.count).to eq(0)

      seed("#{peer}/issues/1.yml", document(iid: 1))
      run_all

      expect(replicas.count).to eq(1)
      expect(replicas.first.issue_id).not_to eq(first_id)
    end

    # The deliberate counterpart to the purge fix. A purge must carry peer
    # directories across, because dropping them is loss. A human removing one
    # is the opposite: it means "stop holding this peer's items", and has to
    # keep meaning that -- which is why there is no guard against
    # whole-directory disappearance in the reconciler.
    it 'deletes every replica of a peer whose directory was pruned' do
      seed_ids
      seed("#{peer}/issues/1.yml", document(iid: 1))
      seed("#{peer}/issues/2.yml", document(iid: 2))
      run_all
      expect(replicas.count).to eq(2)

      ["#{peer}/issues/1.yml", "#{peer}/issues/2.yml", "#{peer}/ids.yml"].each do |path|
        project.repository.delete_file(
          project.first_owner, path, message: 'peer departed', branch_name: branch)
      end

      run_all

      expect(replicas.count).to eq(0)
      expect(project.issues.reload).to be_empty
    end

    # The authorization split. A push-triggered run is allowed every peer
    # because an Owner pushed it; the nightly has no pusher and may only touch
    # pairs already imported, or it becomes a way around the Owner check.
    describe 'restricting which peers a run may touch' do
      let(:other_peer) { '99999999-8888-7777-6666-555555555555' }

      before do
        declare(peer, other_peer)
        seed_ids
        seed("#{peer}/issues/1.yml", document(iid: 1))
        seed("#{other_peer}/issues/1.yml", document(iid: 1))
      end

      it 'takes every declared peer by default' do
        run_all

        expect(replicas.map(&:source_instance_uuid)).to contain_exactly(peer, other_peer)
      end

      it 'touches only the peers it was given' do
        service.execute(directories: [peer])

        expect(replicas.map(&:source_instance_uuid)).to contain_exactly(peer)
      end

      # The nightly's bound and the file's declarations are different questions
      # -- one is "was this ever authorized", the other "was this ever meant" --
      # and a run has to satisfy both.
      it 'ignores a peer it was given but nobody declared' do
        declare(peer)

        service.execute(directories: [peer, other_peer])

        expect(replicas.map(&:source_instance_uuid)).to contain_exactly(peer)
      end
    end

    # The Owner check says the reading is authorized. It does not say which of
    # the directories on a shared branch were meant to be mirrored here, and
    # before this file there was nothing that did: a directory arriving through
    # a fork, a mirror or a merge had its issues created here.
    describe 'importing only what the branch declares' do
      let(:undeclared) { '99999999-8888-7777-6666-555555555555' }

      before do
        seed_ids
        seed("#{peer}/issues/1.yml", document(iid: 1))
        seed("#{undeclared}/issues/1.yml", document(iid: 1))
        seed("#{undeclared}/#{OC::WorkItems::RecordSerializer::IDENTITIES_KEY}.yml", "---\n")
      end

      it 'leaves an undeclared directory alone' do
        run_all

        expect(replicas.map(&:source_instance_uuid)).to contain_exactly(peer)
      end

      it 'imports nothing at all when there is no sync.yml' do
        project.repository.delete_file(
          project.first_owner, OC::WorkItems::SyncFile::PATH,
          message: 'no thanks', branch_name: branch)

        expect { run_all }.not_to change { OC::WorkItems::ReplicatedWorkItem.count }.from(0)
      end

      it 'imports nothing when the file is one this build cannot read' do
        write(OC::WorkItems::SyncFile::PATH, "---\n_schema: sync@99\n")

        expect { run_all }.not_to change { OC::WorkItems::ReplicatedWorkItem.count }.from(0)
      end

      # Withdrawing a declaration says "stop mirroring this peer", not "throw
      # away what you mirrored". Removing the directory from the branch remains
      # the one thing that means the second.
      it 'stops updating a withdrawn peer without deleting anything' do
        run_all
        expect(replicas.count).to eq(1)

        write(OC::WorkItems::SyncFile::PATH, "---\n_schema: sync@1\n")
        project.repository.update_file(
          project.first_owner, "#{peer}/issues/1.yml", document(iid: 1, title: 'Changed'),
          message: 'peer push', branch_name: branch)
        run_all

        expect(replicas.count).to eq(1)
        expect(project.issues.reload.map(&:title)).to contain_exactly('Imported')
      end
    end

    # The migration mode: replicate only what the peer currently gives us,
    # rather than their whole directory.
    describe 'import: transferred' do
      def declare_transferred(*paths)
        transfer = paths.empty? ? 'transfer: all' : "transfer:\n#{paths.map { |p| "        - #{p}" }.join("\n")}"

        write(OC::WorkItems::SyncFile::PATH, <<~YAML)
          ---
          _schema: sync@1
          them:
            uuid: #{peer}
            sync:
              us:
                #{transfer}
          us:
            uuid: #{OC::WorkItems.instance_directory}
            sync:
              them:
                import: transferred
        YAML
      end

      before do
        seed_ids
        seed("#{peer}/issues/1.yml", document(iid: 1, title: 'Given'))
        seed("#{peer}/issues/2.yml", document(iid: 2, title: 'Kept'))
      end

      it 'imports only the items the peer names' do
        declare_transferred('issues/1.yml')

        run_all

        expect(project.issues.map(&:title)).to contain_exactly('Given')
      end

      it 'imports every issue when the peer transfers everything' do
        declare_transferred

        run_all

        expect(project.issues.map(&:title)).to contain_exactly('Given', 'Kept')
      end

      # Without this the run would read every row outside the transfer set as a
      # file that had vanished, and delete replicas nobody asked it to.
      it 'does not delete a replica the peer stopped naming' do
        declare_transferred('issues/1.yml', 'issues/2.yml')
        run_all
        expect(replicas.count).to eq(2)

        declare_transferred('issues/1.yml')
        run_all

        expect(replicas.count).to eq(2)
        expect(project.issues.reload.count).to eq(2)
      end
    end

    # A matched row says a peer's document describes an item that was already
    # here. The record is native, and the peer deleting their file says nothing
    # about ours -- but the generic remove path destroys the row's record, so
    # without this the peer could delete an item this instance owns.
    it 'drops a matched row without touching the record it named' do
      declare(peer)
      seed_ids
      seed("#{peer}/issues/1.yml", document(iid: 1))
      native = create(:issue, project: project, title: 'Ours all along')
      create(:oc_replicated_work_item, :matched, project: project, issue: native,
        source_instance_uuid: peer, source_path: "#{peer}/issues/1.yml", source_iid: 1)

      project.repository.delete_file(
        project.first_owner, "#{peer}/issues/1.yml", message: 'peer dropped it',
        branch_name: branch)
      run_all

      expect(replicas.count).to eq(0)
      expect(native.reload).to be_persisted
    end

    # An instance giving items away and taking none -- the shape of a
    # migration, and what the docs recommend for one -- declares no import at
    # all. It still has to see the documents of the instance it gave them to,
    # or its frozen items can never be let go of, and the freeze is permanent
    # by design.
    describe 'finishing a transfer with no import declared' do
      let(:original) { create(:issue, project: project, title: 'Was ours') }
      let(:old_path) { sync_path("issues/#{original.iid}.yml") }

      let(:handed_back) do
        <<~YAML
          #{document(iid: 7, title: 'Theirs now')}transferred_from: #{old_path}
        YAML
      end

      before do
        # Their block gives to us; we declare nothing at all.
        write(OC::WorkItems::SyncFile::PATH, "---\n_schema: sync@1\n")
        seed_ids
        seed("#{peer}/issues/7.yml", handed_back)
        seed("#{peer}/issues/8.yml", document(iid: 8, title: 'Not ours'))
      end

      it 'acts on the document that finishes ours, and on nothing else' do
        create(:oc_replicated_work_item, project: project, issue: original,
          state: :surrendered, source_instance_uuid: peer, source_path: old_path,
          source_iid: original.iid, source_web_url: nil)

        run_all

        expect(replicas.count).to eq(1)
        expect(replicas.first).to have_attributes(
          state: 'imported', source_path: "#{peer}/issues/7.yml")
        expect(project.issues.reload.map(&:title)).to contain_exactly('Theirs now')
      end

      # A peer cannot get its directory read by declaring something: the row
      # that opens the scan is only ever written by an Owner-authorized freeze
      # on this instance.
      it 'does not scan the directory at all without a promise of ours' do
        expect { run_all }.not_to change { OC::WorkItems::ReplicatedWorkItem.count }.from(0)
        expect(project.issues.reload.map(&:title)).to contain_exactly('Was ours')
      end
    end

    # A plan is taken from rows and executed later. Until transfers existed
    # that was harmless -- every action converged, so acting on a stale one
    # cost a rebuild. A row that was a copy when the plan was made can be an
    # item this instance owns by the time the action runs, and both actions
    # that could follow begin by destroying the record.
    describe 'an action planned before a concurrent run promoted its row' do
      before do
        declare(peer)
        seed_ids
        seed("#{peer}/issues/1.yml", document(iid: 1, title: 'Before'))
        run_all
      end

      # The promote lands after the plan is taken and before its actions run,
      # which is exactly the window the guard exists for: Sidekiq
      # deduplication stops a second job being enqueued, not two that are
      # already running, and this design has no leases.
      def promote_between_plan_and_action
        allow_any_instance_of(OC::WorkItems::ImportReconciler) # rubocop: disable RSpec/AnyInstanceOf -- the instance is built inside the code under test
          .to receive(:plan).and_wrap_original do |original, *args, **kwargs|
            actions = original.call(*args, **kwargs)
            replicas.first.update!(state: :adopted)
            actions
          end
      end

      it 'does not destroy the promoted item on a rebuild' do
        project.repository.update_file(
          project.first_owner, "#{peer}/issues/1.yml", document(iid: 1, title: 'After'),
          message: 'peer push', branch_name: branch)
        promote_between_plan_and_action

        run_all

        expect(project.issues.reload.map(&:title)).to contain_exactly('Before')
        expect(replicas.first).to be_state_adopted
      end

      it 'does not destroy the promoted item on a delete' do
        project.repository.delete_file(
          project.first_owner, "#{peer}/issues/1.yml", message: 'peer dropped it',
          branch_name: branch)
        promote_between_plan_and_action

        run_all

        expect(project.issues.reload.count).to eq(1)
        expect(replicas.first).to be_state_adopted
      end
    end

    # Who everyone the mapping could not place becomes here. Attributing to the
    # ghost is honest but not always useful: an instance draining into another
    # would rather its unmatched people landed on an account that can be
    # assigned and mentioned.
    describe 'default_user' do
      let(:ghost_id) { Users::Internal.in_organization(project.organization).ghost.id }

      before do
        seed_ids
        seed("#{peer}/issues/1.yml", document(iid: 1))
      end

      it 'attributes unmapped users to the ghost by default' do
        run_all

        expect(project.issues.first.author_id).to eq(ghost_id)
      end

      it 'attributes them to a declared member instead' do
        member = create(:user)
        project.add_developer(member)
        declare(peer, default_user: member.username)

        run_all

        expect(project.issues.first.author_id).to eq(member.id)
      end

      # A project access token's bot user is a member like any other, and a
      # service account is what the docs recommend for this.
      it 'accepts a bot member' do
        bot = create(:user, :project_bot)
        project.add_developer(bot)
        declare(peer, default_user: bot.username)

        run_all

        expect(project.issues.first.author_id).to eq(bot.id)
      end

      it 'accepts an admin who is not a member' do
        admin = create(:user, :admin)
        declare(peer, default_user: admin.username)

        run_all

        expect(project.issues.first.author_id).to eq(admin.id)
      end

      # The pair waits rather than falling back to the ghost: importing the
      # peer's items attributed to somebody other than the account that was
      # asked for is worse than importing them later, and the declaration can
      # become satisfiable at any time.
      it 'imports nothing from that peer while the account cannot be used' do
        declare(peer, default_user: 'not-here-yet')

        expect(::Gitlab::AppLogger).to receive(:info).with(hash_including(:default_user))

        expect { run_all }.not_to change { OC::WorkItems::ReplicatedWorkItem.count }.from(0)
      end

      it 'waits for a user who exists but has no access here' do
        outsider = create(:user)
        declare(peer, default_user: outsider.username)

        expect { run_all }.not_to change { OC::WorkItems::ReplicatedWorkItem.count }.from(0)
      end

      it 'picks the import up once the account joins' do
        outsider = create(:user)
        declare(peer, default_user: outsider.username)
        run_all

        project.add_reporter(outsider)
        run_all

        expect(project.issues.first.author_id).to eq(outsider.id)
      end

      # default_user changes who the item belongs to here, not who wrote it
      # there: the byline keys off identities that actually resolved.
      it 'leaves the byline naming the original author' do
        member = create(:user)
        project.add_developer(member)
        declare(peer, default_user: member.username)

        run_all

        expect(project.issues.first.description).to include('*By Remote Author')
      end
    end

    # One document nobody can build should cost one document. Letting it
    # escape abandons every remaining file and every later directory, and does
    # it again on every retry, since the same bytes fail the same way.
    describe 'a document that will not build' do
      it 'costs one document, not the run' do
        seed_ids
        seed("#{peer}/issues/1.yml", "---\n  : not: valid: yaml\n")
        seed("#{peer}/issues/2.yml", document(iid: 2, title: 'Fine'))

        expect { run_all }.not_to raise_error
        expect(project.issues.map(&:title)).to contain_exactly('Fine')
      end

      # The case that matters, and the one unparseable YAML does not reach:
      # a document that reads perfectly and then will not save. Version drift
      # between builds is enough to produce one.
      it 'costs one document when it parses and then fails to build' do
        seed_ids
        seed("#{peer}/issues/1.yml", document(iid: 1, title: 'x' * 300))
        seed("#{peer}/issues/2.yml", document(iid: 2, title: 'Fine'))

        expect { run_all }.not_to raise_error

        expect(project.issues.map(&:title)).to contain_exactly('Fine')
        expect(replicas.find_by(source_iid: 1)).to be_state_errored
        expect(replicas.find_by(source_iid: 2)).to be_state_imported
      end

      # A concurrent run got there first. The unique index doing its job is not
      # an error, and must not take the rest of the run down with it.
      it 'treats losing a race to another run as done' do
        seed_ids
        seed("#{peer}/issues/1.yml", document(iid: 1))
        seed("#{peer}/issues/2.yml", document(iid: 2, title: 'Fine'))

        allow_any_instance_of(OC::WorkItems::ImportService) # rubocop: disable RSpec/AnyInstanceOf -- the instance is built inside the code under test
          .to receive(:import).and_wrap_original do |original, action, doc|
            raise ActiveRecord::RecordNotUnique, 'beaten to it' if action.source_iid == 1

            original.call(action, doc)
          end

        expect { run_all }.not_to raise_error
        expect(project.issues.map(&:title)).to contain_exactly('Fine')
        expect(replicas.find_by(source_iid: 1)).to be_nil
      end

      it 'records why, so the failure is findable' do
        seed_ids
        seed("#{peer}/issues/1.yml", "---\n  : not: valid: yaml\n")

        run_all

        row = replicas.find_by(source_iid: 1)
        expect(row).to be_state_errored
        expect(row.reason).to be_present
      end

      # The same bytes will fail the same way for ever, so the run must stop
      # asking. Without a row it would re-read and re-fail on every run.
      it 'does not try again while the file is unchanged' do
        seed_ids
        seed("#{peer}/issues/1.yml", "---\n  : not: valid: yaml\n")
        run_all

        expect(described_class.new(project)).not_to receive(:apply)

        run_all
        expect(replicas.count).to eq(1)
      end

      it 'tries again once the file changes' do
        seed_ids
        seed("#{peer}/issues/1.yml", "---\n  : not: valid: yaml\n")
        run_all
        expect(replicas.find_by(source_iid: 1)).to be_state_errored

        project.repository.update_file(
          project.first_owner, "#{peer}/issues/1.yml", document(iid: 1, title: 'Fixed'),
          message: 'peer fixed it', branch_name: branch)
        run_all

        expect(replicas.find_by(source_iid: 1)).to be_state_imported
        expect(project.issues.map(&:title)).to contain_exactly('Fixed')
      end

      # A build failure on a rebuild leaves the copy made from the previous
      # version standing: a stale copy is a truer thing to show than nothing.
      it 'keeps the record a failed rebuild replaced' do
        seed_ids
        seed("#{peer}/issues/1.yml", document(iid: 1, title: 'Original'))
        run_all

        project.repository.update_file(
          project.first_owner, "#{peer}/issues/1.yml", "---\n  : broken:\n",
          message: 'peer broke it', branch_name: branch)
        run_all

        expect(replicas.find_by(source_iid: 1)).to be_state_errored
        expect(project.issues.reload.map(&:title)).to contain_exactly('Original')
      end
    end
  end
end
