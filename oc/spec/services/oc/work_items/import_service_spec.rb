# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../support/helpers/work_item_sync_paths'

RSpec.describe OC::WorkItems::ImportService, feature_category: :source_code_management do
  let(:project) { create(:project) }
  let(:peer) { '11111111-2222-3333-4444-555555555555' }
  let(:trust) { :none }

  # Shaped like what RecordSerializer writes, including the keys this fork adds
  # on top of the export schema.
  let(:document) do
    {
      '_schema' => 'issues@1',
      'title' => 'Deploy fails on public blueprints',
      'description' => 'The deploy step exits 1.',
      'author_id' => 12,
      'project_id' => 99,
      'iid' => 42,
      'state' => 'opened',
      'confidential' => false,
      'created_at' => '2026-03-14T09:00:00.000Z',
      'updated_at' => '2026-03-14T09:00:00.000Z',
      'web_url' => 'https://peer.example.com/group/project/-/issues/42',
      'uploads' => ['https://peer.example.com/uploads/x/y.png'],
      'notes' => [
        {
          'note' => 'I can reproduce this.',
          'author_id' => 34,
          'created_at' => '2026-03-14T10:00:00.000Z',
          'updated_at' => '2026-03-14T10:00:00.000Z',
          'author' => { 'name' => 'Remote Commenter' }
        }
      ]
    }
  end

  # The peer's whole ids.yml. The projects section is what lets a link back to
  # the source be built: subtracting the path out of an item's web_url is the
  # only exact way to find the peer's base URL.
  let(:identities) do
    {
      'projects' => { 99 => 'group/project' },
      'users' => {
        12 => { 'username' => 'remote-author', 'name' => 'Remote Author',
                'public_email' => 'author@peer.example.com' },
        34 => { 'username' => 'remote-commenter', 'name' => 'Remote Commenter' }
      }
    }
  end

  let(:action) do
    OC::WorkItems::ImportReconciler::Action.new(
      kind: :import, path: "#{peer}/issues/42.yml", oid: 'a' * 40,
      source_kind: :issue, source_iid: 42)
  end

  let(:service) do
    described_class.new(project, source_instance_uuid: peer,
      identities: identities, trust: trust)
  end

  describe '#import' do
    it 'builds the issue and records the row that describes it' do
      replica = service.import(action, document)

      issue = replica.issue
      expect(issue.title).to eq('Deploy fails on public blueprints')
      expect(replica).to have_attributes(
        project: project, source_instance_uuid: peer, source_path: "#{peer}/issues/42.yml",
        source_blob_oid: 'a' * 40, source_iid: 42, state: 'imported',
        source_web_url: 'https://peer.example.com/group/project/-/issues/42')
      expect(replica).to be_source_issue
    end

    # The reason for using the import/export machinery at all rather than
    # Issues::CreateService, which would allocate a fresh iid.
    it 'keeps the iid the source instance gave it' do
      replica = service.import(action, document)

      expect(replica.issue.iid).to eq(42)
    end

    it 'brings the comments with it' do
      replica = service.import(action, document)

      expect(replica.issue.notes.map(&:note)).to include(a_string_including('I can reproduce this.'))
    end

    # The replica banner already says where the item came from; GitLab's
    # "Imported" badge next to it would say so a second time.
    it 'does not mark the replica or its comments as imported' do
      replica = service.import(action, document)

      expect(replica.issue).not_to be_imported
      expect(replica.issue.notes).to all(have_attributes(imported?: false))
    end

    it 'strips the keys this fork adds, which no model has an attribute for' do
      expect { service.import(action, document) }.not_to raise_error
    end

    describe 'attribution' do
      it 'authors the replica as the ghost user' do
        replica = service.import(action, document)

        expect(replica.issue.author).to eq(Users::Internal.in_organization(project.organization).ghost)
      end

      # Upstream writes a byline onto notes but not onto the issue itself,
      # which would leave an imported issue looking self-authored.
      it 'names the original author in the description' do
        replica = service.import(action, document)

        expect(replica.issue.description).to include('The deploy step exits 1.')
        expect(replica.issue.description)
          .to include('*By Remote Author on 2026-03-14 (imported from GitLab)*')
      end

      it 'still says who wrote it when the description was empty' do
        replica = service.import(action, document.merge('description' => nil))

        expect(replica.issue.description).to eq('*By Remote Author on 2026-03-14 (imported from GitLab)*')
      end

      context 'when identities are matched by verified email' do
        let(:trust) { :email }
        let!(:local) { create(:user, username: 'someone-else', email: 'author@peer.example.com') }

        before do
          local.update!(public_email: 'author@peer.example.com')
        end

        it 'attributes the issue to the matching local user and drops the byline' do
          replica = service.import(action, document)

          expect(replica.issue.author).to eq(local)
          expect(replica.issue.description).not_to include('imported from GitLab')
        end

        # The commenter published no address, and matching a name is a
        # separate, weaker decision that this level did not ask for.
        it 'leaves someone with no published address to the ghost user' do
          create(:user, username: 'remote-commenter')

          replica = service.import(action, document)

          expect(replica.issue.notes.first.author).to eq(Users::Internal.in_organization(project.organization).ghost)
        end
      end

      context 'when identities are also matched by username' do
        let(:trust) { :username }
        let!(:by_name) { create(:user, username: 'remote-commenter') }

        it 'matches the person a name is all we have for' do
          replica = service.import(action, document)

          expect(replica.issue.notes.first.author).to eq(by_name)
        end
      end
    end

    # A group reaches a work item document only through a label it owns, so
    # that is the only place the correspondence can be read from. Paired by
    # title, because that is how ObjectBuilder paired the labels themselves.
    describe 'groups' do
      let(:group) { create(:group) }
      let(:project) { create(:project, group: group) }
      let!(:group_label) { create(:group_label, group: group, title: 'inherited') }

      let(:labelled) do
        document.merge('label_links' => [
          { 'target_type' => 'Issue',
            'label' => { 'title' => 'inherited', 'group_id' => 555, 'type' => 'GroupLabel' } }
        ])
      end

      it 'records which local group the source group turned out to be' do
        replica = service.import(action, labelled)

        expect(replica.issue.labels).to include(group_label)
        expect(replica.identities['groups']).to eq(group.id.to_s => 555)
      end

      it 'records nothing for a label the source project owned itself' do
        replica = service.import(action, document.merge('label_links' => [
          { 'target_type' => 'Issue',
            'label' => { 'title' => 'bug', 'project_id' => 99, 'type' => 'ProjectLabel' } }
        ]))

        expect(replica.identities).not_to have_key('groups')
      end
    end

    # A mention resolves to whichever local account holds the name, and
    # store_mentions! then records that person as mentioned in an item that is
    # not about them. It sends no mail -- an import never reaches
    # Notes::CreateService, which is what enqueues NewNoteWorker -- but the
    # index entry and the profile link are both simply wrong.
    describe 'mentions' do
      let(:mentioning) { document.merge('description' => 'ask @remote-author about it') }

      it 'links to the profile on the source instance when nobody here is her' do
        replica = service.import(action, mentioning)

        expect(replica.issue.description).to include(
          '[@remote-author](https://peer.example.com/remote-author)')
      end

      # Only names that appear as an author or assignee reach ids.yml, so most
      # mentions in prose are names this instance has never heard of.
      it 'links an unknown name to the source instance too' do
        replica = service.import(action, document.merge('description' => 'ask @someone-else'))

        expect(replica.issue.description).to include(
          '[@someone-else](https://peer.example.com/someone-else)')
      end

      context 'when identities are matched by verified email' do
        let(:trust) { :email }
        let!(:local) { create(:user, username: 'local-jane', email: 'author@peer.example.com') }

        before do
          local.update!(public_email: 'author@peer.example.com')
        end

        # A real mention, under the local name -- which differs from the
        # source's, and is why leaving the text alone would be wrong even here.
        it 'mentions the matched local account by its own name' do
          replica = service.import(action, mentioning)

          expect(replica.issue.description).to include('ask @local-jane about it')
          expect(replica.issue.description).not_to include('peer.example.com')
        end
      end
    end

    describe 'rebuilding' do
      it 'replaces the record and keeps the row, under the same iid' do
        replica = service.import(action, document)
        original_id = replica.issue_id

        changed = document.merge('title' => 'Deploy fails everywhere')
        rebuild = OC::WorkItems::ImportReconciler::Action.new(
          kind: :rebuild, path: action.path, oid: 'b' * 40, replica: replica.reload,
          source_kind: :issue, source_iid: 42)

        result = service.import(rebuild, changed)

        expect(result.id).to eq(replica.id)
        expect(result.issue_id).not_to eq(original_id)
        expect(result.issue.title).to eq('Deploy fails everywhere')
        expect(result.issue.iid).to eq(42)
        expect(result.source_blob_oid).to eq('b' * 40)
        expect(Issue.id_in(original_id)).to be_empty
      end
    end

    # A rebuild destroys and recreates, and every one of those fires a trigger
    # that would queue a sync for a file this run writes itself.
    it 'queues no sync jobs of its own' do
      project.enable_work_items_sync!(true)

      expect(OC::WorkItems::SyncWorker).not_to receive(:perform_in)

      service.import(action, document)
    end

    # Turns up when a peer holds replicas of a third instance and pushes its
    # branch onward. The pointer has nothing to build a record from -- but the
    # third instance's real documents travel in the same branch under their
    # own directory, and are imported first-hand from there.
    # The scenario rewriting has to survive: source issue 10 references source
    # issue 20, both are imported in one session, and weeks later 10 changes
    # while 20 does not. Rebuilding 10 has to work out again that the source's
    # 20 is our local record -- and nothing about that is remembered in 10.
    #
    # It is recorded on 20's own row, under the same unique index the reconcile
    # uses. Rewriting the text is step 7; what is pinned here is the lookup it
    # will depend on, and that a rebuild of one item leaves another's mapping
    # untouched.
    describe 'a reference from one imported item to another' do
      def source_action(iid, oid, kind: :import, replica: nil)
        OC::WorkItems::ImportReconciler::Action.new(
          kind: kind, path: "#{peer}/issues/#{iid}.yml", oid: oid,
          replica: replica, source_kind: :issue, source_iid: iid)
      end

      # How the rewriter will resolve "the source's issue N": the source iid
      # becomes a path, and the path is what the unique index covers. There is
      # no index on source_iid, so looking it up directly would be a scan.
      def resolve(iid)
        OC::WorkItems::ReplicatedWorkItem.find_by(
          project_id: project.id, source_instance_uuid: peer,
          source_path: "#{peer}/issues/#{iid}.yml")
      end

      # The rewriting half of the same scenario: the referrer's text has to
      # come out pointing at the local record, both when first imported and
      # again after a rebuild weeks later.
      it 'rewrites the reference to the local item, and still does after a rebuild' do
        referenced = service.import(
          source_action(20, 'd' * 40), document.merge('iid' => 20, 'title' => 'Referenced'))
        referrer = service.import(
          source_action(10, 'e' * 40),
          document.merge('iid' => 10, 'title' => 'Referrer', 'description' => 'blocked by #20'))

        local_iid = referenced.issue.iid
        expect(referrer.issue.description).to include("blocked by ##{local_iid}")
        expect(referrer.issue.description).not_to include('peer.example.com')

        rebuilt = service.import(
          source_action(10, 'f' * 40, kind: :rebuild, replica: resolve(10)),
          document.merge('iid' => 10, 'title' => 'Referrer, edited',
            'description' => 'still blocked by #20'))

        expect(rebuilt.issue.description).to include("still blocked by ##{local_iid}")
      end

      # Wrong is worse than broken: an unrewritten #20 renders as a link to
      # *our* issue 20, a different item, silently.
      it 'links back to the source when the referenced item is not here' do
        referrer = service.import(
          source_action(10, 'e' * 40),
          document.merge('iid' => 10, 'description' => 'blocked by #999'))

        expect(referrer.issue.description).to include(
          '[#999](https://peer.example.com/group/project/-/issues/999)')
        expect(service.unresolved_references).to include(999)
      end

      # A path that resolves here is a *different* project that happens to
      # share a name, so resolving it locally would be the exact mistake this
      # rewriting exists to prevent.
      it 'links a reference naming another project back to the source' do
        referrer = service.import(
          source_action(10, 'e' * 40),
          document.merge('iid' => 10, 'description' => 'see other/thing#5'))

        expect(referrer.issue.description).to include(
          '[other/thing#5](https://peer.example.com/other/thing/-/issues/5)')
      end

      # Naming the source's own project is the same thing a bare reference
      # says, just the long way round.
      it 'resolves a reference naming the source project itself' do
        referenced = service.import(
          source_action(20, 'd' * 40), document.merge('iid' => 20))
        referrer = service.import(
          source_action(10, 'e' * 40),
          document.merge('iid' => 10, 'description' => 'see group/project#20'))

        expect(referrer.issue.description).to include("see ##{referenced.issue.iid}")
      end

      it 'reports nothing unresolved once everything it referred to is here' do
        service.import(source_action(20, 'd' * 40), document.merge('iid' => 20))
        service.import(
          source_action(10, 'e' * 40), document.merge('iid' => 10, 'description' => 'see #20'))

        expect(service.unresolved_references).to be_empty
      end

      it 'still resolves the referenced item after the referrer is rebuilt' do
        referenced = service.import(
          source_action(20, 'd' * 40), document.merge('iid' => 20, 'title' => 'Referenced'))
        referrer = service.import(
          source_action(10, 'e' * 40),
          document.merge('iid' => 10, 'title' => 'Referrer', 'description' => 'blocked by #20'))

        local_id = referenced.issue_id
        original_referrer_id = referrer.issue_id
        expect(local_id).to be_present

        # Weeks later: 10 changes, 20 does not.
        rebuilt = service.import(
          source_action(10, 'f' * 40, kind: :rebuild, replica: resolve(10)),
          document.merge('iid' => 10, 'title' => 'Referrer, edited',
            'description' => 'blocked by #20'))

        # Really a rebuild: the referrer's record was destroyed and another
        # built in its place. Without this the example would pass just as
        # happily against an in-place update, which is not what happens.
        expect(rebuilt.issue_id).not_to eq(original_referrer_id)
        expect(Issue.id_in(original_referrer_id)).to be_empty
        expect(rebuilt.issue.title).to eq('Referrer, edited')
        expect(rebuilt.issue.iid).to eq(10)

        # And the referenced item's mapping came through it untouched.
        expect(resolve(20).issue_id).to eq(local_id)
        expect(resolve(20).issue).to be_present
        expect(resolve(20).issue.iid).to eq(20)
      end

      # Lets the rewriter tell "not imported yet, fall back to the source URL
      # and rebuild me when it lands" from "no such item, leave it alone".
      it 'records a row for an item that could not be built yet' do
        merge_request_action = OC::WorkItems::ImportReconciler::Action.new(
          kind: :import, path: "#{peer}/merge_requests/5.yml", oid: 'g' * 40,
          source_kind: :merge_request, source_iid: 5)

        service.import(merge_request_action, {
          '_schema' => 'merge_requests@1', 'title' => 'Waiting', 'author_id' => 12,
          'iid' => 5, 'state' => 'opened', 'source_branch' => 'a', 'target_branch' => 'b',
          'source_project_id' => 99, 'target_project_id' => 99,
          'created_at' => '2026-03-14T09:00:00.000Z', 'updated_at' => '2026-03-14T09:00:00.000Z',
          'merge_request_diff' => nil
        })

        row = OC::WorkItems::ReplicatedWorkItem.find_by(
          project_id: project.id, source_instance_uuid: peer,
          source_path: "#{peer}/merge_requests/5.yml")

        expect(row).to be_present
        expect(row.work_item).to be_nil
        expect(row).to be_state_deferred
      end
    end

    # Keeping the source's number is only safe if the project is told the
    # number is now taken. has_internal_id skips its tracking callback while
    # importing, so without that the project's counter stays behind: the next
    # issue anyone files is handed a number this import already took, the
    # insert fails on the unique index, and the rollback reverts the counter
    # increment along with it -- so the retry produces the same number and
    # fails again, permanently.
    it 'tells the project a kept number is taken, so it can still number its own' do
      create(:issue, project: project) # iid 1, counter at 1

      service.import(
        OC::WorkItems::ImportReconciler::Action.new(
          kind: :import, path: "#{peer}/issues/2.yml", oid: 'y' * 40,
          source_kind: :issue, source_iid: 2),
        document.merge('iid' => 2))

      expect { create(:issue, project: project) }.not_to raise_error
      expect(project.issues.reload.map(&:iid)).to contain_exactly(1, 2, 3)
    end

    # Two instances can sync their own items to one branch, so both having an
    # issue 1 is ordinary. Before this the second one imported simply failed on
    # the unique index.
    describe 'when the receiving project already uses that number' do
      before do
        create(:issue, project: project).update_columns(iid: 42)
      end

      it 'imports under a number of its own rather than failing' do
        replica = service.import(action, document)

        expect(replica).to be_state_imported
        expect(replica.issue.iid).not_to eq(42)
        # The correspondence is kept on the row, which is what the reference
        # rewriting resolves through.
        expect(replica.source_iid).to eq(42)
      end

      # max(iid) + 1 by hand would leave the project's internal id counter
      # behind, and the next issue anyone filed would collide.
      it 'leaves the project able to number its own next issue' do
        service.import(action, document)

        expect { create(:issue, project: project) }.not_to raise_error
      end

      it 'keeps the source number when nothing local holds it' do
        replica = service.import(
          OC::WorkItems::ImportReconciler::Action.new(
            kind: :import, path: "#{peer}/issues/77.yml", oid: 'z' * 40,
            source_kind: :issue, source_iid: 77),
          document.merge('iid' => 77))

        expect(replica.issue.iid).to eq(77)
      end
    end

    describe 'a reference file on the peer branch' do
      let(:reference) do
        {
          '_schema' => 'issue_reference@1',
          'source_path' => '99999999-8888-7777-6666-555555555555/issues/3.yml',
          'source_web_url' => 'https://third.example.com/g/p/-/issues/3',
          'web_url' => 'https://peer.example.com/g/p/-/issues/42'
        }
      end

      it 'builds nothing and says why' do
        replica = service.import(action, reference)

        expect(replica.work_item).to be_nil
        expect(replica).to be_state_skipped
        expect(replica.reason).to eq('reference to an item on another instance')
        expect(Issue.count).to eq(0)
      end

      it 'records the oid, so the nightly does not re-read it forever' do
        expect(service.import(action, reference).source_blob_oid).to eq('a' * 40)
      end
    end

    describe 'confidential documents' do
      let(:confidential) { document.merge('confidential' => true) }

      it 'builds nothing, but records that it looked' do
        replica = service.import(action, confidential)

        expect(replica.work_item).to be_nil
        expect(replica).to be_state_skipped
        expect(replica.reason).to eq('confidential')
        # The oid is kept so the nightly does not re-read and re-parse the same
        # blob every night to reach the same conclusion.
        expect(replica.source_blob_oid).to eq('a' * 40)
        expect(Issue.count).to eq(0)
      end

      it 'destroys a replica whose source has since become confidential' do
        replica = service.import(action, document)
        issue_id = replica.issue_id

        rebuild = OC::WorkItems::ImportReconciler::Action.new(
          kind: :rebuild, path: action.path, oid: 'b' * 40, replica: replica.reload,
          source_kind: :issue, source_iid: 42)

        result = service.import(rebuild, confidential)

        expect(result.id).to eq(replica.id)
        expect(result).to be_state_skipped
        expect(result.issue_id).to be_nil
        expect(Issue.id_in(issue_id)).to be_empty
      end
    end

    describe 'merge requests' do
      let(:project) { create(:project, :repository) }
      let(:sha) { project.commit.sha }

      let(:merge_request_action) do
        OC::WorkItems::ImportReconciler::Action.new(
          kind: :import, path: "#{peer}/merge_requests/7.yml", oid: 'c' * 40,
          source_kind: :merge_request, source_iid: 7)
      end

      def merge_request_document(diff)
        {
          '_schema' => 'merge_requests@1',
          'title' => 'Fix the deploy step',
          'description' => 'A fix.',
          'author_id' => 12,
          'iid' => 7,
          'state' => 'opened',
          'source_branch' => 'feature',
          'target_branch' => 'master',
          'source_project_id' => 99,
          'target_project_id' => 99,
          'created_at' => '2026-03-14T09:00:00.000Z',
          'updated_at' => '2026-03-14T09:00:00.000Z',
          'web_url' => 'https://peer.example.com/group/project/-/merge_requests/7',
          'merge_request_diff' => diff
        }
      end

      it 'imports one whose diff commits are all present locally' do
        document = merge_request_document(
          'base_commit_sha' => sha, 'start_commit_sha' => sha, 'head_commit_sha' => sha)

        replica = service.import(merge_request_action, document)

        expect(replica).to be_state_imported
        expect(replica.merge_request.iid).to eq(7)
        expect(replica.merge_request.merge_request_diff.head_commit_sha).to eq(sha)
      end

      # Deferred rather than skipped: the commits usually turn up, just not in
      # the same push, and the source may be a fork we never receive.
      it 'defers one whose diff commits are missing, saying which' do
        absent = 'f0c7d1a94e3b6528d0b1f4a27c9e83b5d6a10f42'
        document = merge_request_document(
          'base_commit_sha' => sha, 'start_commit_sha' => absent, 'head_commit_sha' => absent)

        replica = service.import(merge_request_action, document)

        expect(replica).to be_state_deferred
        expect(replica.work_item).to be_nil
        expect(replica.reason).to eq('diff commits not present: start_commit_sha, head_commit_sha')
        expect(MergeRequest.count).to eq(0)
      end

      it 'defers one with no diff at all rather than building half of it' do
        replica = service.import(merge_request_action, merge_request_document(nil))

        expect(replica).to be_state_deferred
        expect(replica.reason).to include('no merge request diff')
      end
    end

    describe 'enabling sync on the receiving project' do
      it 'turns sync on once a replica lands, so the project maintains its own files' do
        expect(project.work_items_sync_enabled?).to be(false)

        service.import(action, document)

        expect(project.reload.work_items_sync_enabled?).to be(true)
      end

      it 'does not import at all into a project that turned sync off' do
        project.enable_work_items_sync!(false)

        expect(service.import(action, document)).to be_nil
        expect(OC::WorkItems::ReplicatedWorkItem.count).to eq(0)
        expect(Issue.count).to eq(0)
        expect(project.reload.work_items_sync_opted_out?).to be(true)
      end

      it 'writes no setting for a project already syncing by default' do
        allow(project).to receive(:work_items_sync_on_by_default?).and_return(true)

        expect(project).not_to receive(:enable_work_items_sync!)

        service.import(action, document)
      end
    end

    it 'leaves nothing behind when the record cannot be saved' do
      allow_next_instance_of(Issue) do |issue|
        allow(issue).to receive(:save!).and_raise(ActiveRecord::RecordInvalid)
      end

      expect { service.import(action, document) }.to raise_error(ActiveRecord::RecordInvalid)
      expect(OC::WorkItems::ReplicatedWorkItem.count).to eq(0)
    end

    # The last step of a transfer, seen from the side that gave the item away:
    # the instance that took it publishes a document stamped with where it came
    # from, and the original here becomes an ordinary copy of that document.
    describe 'a document that says it used to be ours' do
      include WorkItemSyncPaths

      let(:original) { create(:issue, project: project, title: 'Was ours', iid: 42) }
      let(:old_path) { sync_path('issues/42.yml') }
      let(:stamped) { document.merge('transferred_from' => old_path, 'iid' => 7) }

      let!(:surrendered) do
        create(:oc_replicated_work_item, project: project, issue: original,
          state: :surrendered, source_instance_uuid: peer, source_path: old_path,
          source_iid: 42, source_web_url: nil)
      end

      def demote
        service.import(
          OC::WorkItems::ImportReconciler::Action.new(
            kind: :import, path: "#{peer}/issues/7.yml", oid: 'd' * 40,
            source_kind: :issue, source_iid: 7),
          stamped)
      end

      it 'replaces the frozen original with a copy of their document' do
        demote

        expect(project.issues.reload.map(&:title)).to contain_exactly(document['title'])
      end

      # Every link anyone ever wrote to .../issues/42 -- in a comment, a commit
      # message, another project, a bookmark -- has to go on resolving to the
      # same item. Their number for it is 7, and taking that would break all of
      # them.
      it 'keeps the number the original had, not the one they gave it' do
        replica = demote

        expect(replica.issue.iid).to eq(42)
      end

      # The demote pins the number so that everything ever written about the
      # item still resolves. A rebuild replaces the record, and taking the new
      # owner's number then -- or a fresh one -- would throw that away on their
      # very first edit.
      it 'keeps that number when the new owner edits it again' do
        replica = demote

        rebuilt = service.import(
          OC::WorkItems::ImportReconciler::Action.new(
            kind: :rebuild, path: "#{peer}/issues/7.yml", oid: 'f' * 40, replica: replica,
            source_kind: :issue, source_iid: 7),
          stamped.merge('title' => 'Theirs now, and edited'))

        expect(rebuilt.issue.iid).to eq(42)
        expect(rebuilt.issue.title).to eq('Theirs now, and edited')
      end

      # Left behind, the surrendered row would name a path nothing writes any
      # more and be invisible to the reconcile, which skips surrendered rows --
      # so it would hold the item read-only through a row nobody could find.
      it 'moves the row it already had rather than opening a second one' do
        replica = demote

        expect(OC::WorkItems::ReplicatedWorkItem.count).to eq(1)
        expect(replica.id).to eq(surrendered.id)
        expect(replica).to have_attributes(
          state: 'imported',
          source_instance_uuid: peer,
          source_path: "#{peer}/issues/7.yml",
          source_blob_oid: 'd' * 40,
          source_web_url: stamped['web_url'])
      end

      it 'is a copy again, so the new owner edits reach it' do
        replica = demote

        expect(replica).to be_read_only
        expect(Ability.allowed?(project.first_owner, :update_issue, replica.issue)).to be(false)
      end

      # Our own directory still holds the document published while the item was
      # ours, and it goes on claiming we own it until something rewrites it as
      # a pointer. Every trigger that would have done so was suppressed for the
      # rebuild, so this one has to be asked for -- and until it happens, any
      # instance mirroring us reads the item as belonging to two places.
      it 'asks for our own file to be rewritten as a pointer' do
        expect(OC::WorkItems).to receive(:enqueue_sync)
          .with(an_object_having_attributes(iid: 42))

        demote
      end

      # The freeze may simply not have been pushed here yet. Importing would
      # build a second copy of an item this instance still holds, and the two
      # would sit side by side with nothing to say which was which.
      it 'waits when nothing here says the item was given away' do
        surrendered.destroy!

        replica = demote

        expect(replica).to be_state_deferred
        expect(project.issues.reload.map(&:title)).to contain_exactly('Was ours')
      end

      # The stamp is written by another instance, so an instance we promised
      # nothing to must not be able to finish a transfer by claiming one.
      it 'waits when it was promised to a different instance' do
        surrendered.update!(source_instance_uuid: '99999999-8888-7777-6666-555555555555')

        replica = demote

        expect(replica).to be_state_deferred
        expect(original.reload).to be_persisted
      end

      # To them it is an ordinary document, and their own copy of the old
      # owner's item converges the way any other changed file does.
      it 'imports a document stamped with somebody else directory as usual' do
        replica = service.import(
          OC::WorkItems::ImportReconciler::Action.new(
            kind: :import, path: "#{peer}/issues/7.yml", oid: 'e' * 40,
            source_kind: :issue, source_iid: 7),
          document.merge('transferred_from' => 'somebody-else/issues/1.yml', 'iid' => 7))

        expect(replica).to be_state_imported
        expect(replica.issue.title).to eq(document['title'])
      end
    end

    # An instance that began as a copy of its peer -- database included, which
    # is how a staging installation usually starts -- already owns a native
    # record of everything the peer had then. Imported as replicas, every one
    # of them would double.
    describe 'a document describing an item that is already here' do
      # Same number, same creation instant: a row copied with the database,
      # which is what the clone case leaves behind. The column keeps
      # microseconds the document cannot, so this also pins that the comparison
      # happens at the document's precision.
      let!(:native) do
        create(:issue, project: project, title: 'Ours', iid: 42,
          created_at: Time.zone.parse('2026-03-14T09:00:00.000456Z'))
      end

      it 'records the two as the same item without building anything' do
        expect { service.import(action, document) }.not_to change { project.issues.count }

        replica = OC::WorkItems::ReplicatedWorkItem.last
        expect(replica).to be_state_matched
        expect(replica.issue).to eq(native)
      end

      it 'leaves the item ours -- untouched, and still editable' do
        service.import(action, document)

        expect(native.reload.title).to eq('Ours')
        expect(native.oc_replica).not_to be_read_only
      end

      # Two instances both having an issue 42 is the ordinary case, and the
      # whole reason the importer reallocates numbers. Only the creation time
      # makes it identity.
      it 'imports a different item that merely shares the number' do
        native.update!(created_at: Time.zone.parse('2020-01-01T00:00:00Z'))

        replica = service.import(action, document)

        expect(replica).to be_state_imported
        expect(replica.issue).not_to eq(native)
        expect(replica.issue.iid).not_to eq(42)
      end

      # A copy is never "already here": it is the copy. Two instances mirroring
      # a third both hold its issue 43, with its creation time -- matching them
      # would make this project's copy of one instance's item stand in for
      # another instance's file, and the two are only equal until either edits
      # theirs.
      #
      # The same guard is what keeps a rebuild working at all: the copy built
      # from a file has that file's number and creation time by construction,
      # so without it every rebuild would match against the record it is
      # supposed to be replacing, and no imported item would ever update again.
      it 'does not match against an item that is itself a copy' do
        third = '33333333-3333-3333-3333-333333333333'
        other = create(:issue, project: project, iid: 43,
          created_at: Time.zone.parse('2026-03-14T09:00:00.000Z'))
        create(:oc_replicated_work_item, project: project, issue: other,
          source_instance_uuid: third, source_iid: 43,
          source_path: "#{third}/issues/43.yml")

        replica = service.import(
          OC::WorkItems::ImportReconciler::Action.new(
            kind: :import, path: "#{peer}/issues/43.yml", oid: 'b' * 40,
            source_kind: :issue, source_iid: 43),
          document.merge('iid' => 43))

        expect(replica).to be_state_imported
        expect(replica.issue).not_to eq(other)
      end

      describe 'when the peer edits their copy' do
        let(:rebuild) do
          OC::WorkItems::ImportReconciler::Action.new(
            kind: :rebuild, path: "#{peer}/issues/42.yml", oid: 'c' * 40,
            replica: OC::WorkItems::ReplicatedWorkItem.last, source_kind: :issue, source_iid: 42)
        end

        before do
          service.import(action, document)
        end

        # Ours wins, and it is not a merge. Deciding between two divergent
        # versions of the same item needs a policy this does not have.
        it 'records the new oid and keeps our own copy' do
          service.import(rebuild, document.merge('title' => 'Theirs, edited'))

          expect(native.reload.title).to eq('Ours')
          expect(OC::WorkItems::ReplicatedWorkItem.last).to have_attributes(
            state: 'matched', source_blob_oid: 'c' * 40)
        end

        # The path now holds a different item. The match has to break -- but
        # the record it was matched against is still ours, and the destroy that
        # ordinarily makes room for a rebuild must not reach it.
        it 'lets go of our item without destroying it when the identity breaks' do
          service.import(rebuild, document.merge('created_at' => '2019-05-05T05:05:05.000Z'))

          expect(native.reload).to be_persisted
          expect(native.reload.oc_replica).to be_nil

          replica = OC::WorkItems::ReplicatedWorkItem.last
          expect(replica).to be_state_imported
          expect(replica.issue).not_to eq(native)
        end

        # Same guard, reached the other way: a document that stops being
        # importable withholds, and that path destroys the record too.
        it 'does not destroy our item when their copy becomes confidential' do
          service.import(rebuild, document.merge('confidential' => true))

          expect(native.reload).to be_persisted
          expect(OC::WorkItems::ReplicatedWorkItem.last).to be_state_skipped
          expect(native.reload.oc_replica).to be_nil
        end
      end
    end
  end
end
