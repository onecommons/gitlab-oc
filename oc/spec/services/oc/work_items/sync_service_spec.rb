# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../support/helpers/work_item_sync_paths'

RSpec.describe OC::WorkItems::SyncService, feature_category: :source_code_management do
  include WorkItemSyncPaths

  let(:project) { create(:project, :repository) }
  let(:issue) { create(:issue, project: project) }
  let(:repository) { project.repository }
  let(:branch) { OC::WorkItems::SYNC_BRANCH }
  let(:service) { described_class.new(project) }

  # Paths are given relative to the instance directory throughout; sync_path
  # supplies the prefix the service writes under.
  def sync_blob(path)
    repository.blob_at(repository.commit(branch).sha, sync_path(path))
  end

  describe '#execute' do
    it 'creates the sync branch as an orphan containing the serialized issue' do
      sha = service.execute([issue])

      commit = repository.commit(branch)
      expect(commit.sha).to eq(sha)
      expect(commit.parent_ids).to be_empty
      expect(commit.message).to start_with(OC::WorkItems::COMMIT_MESSAGE)

      data = YAML.safe_load(sync_blob("issues/#{issue.iid}.yml").data)
      expect(data['title']).to eq(issue.title)
      expect(data['iid']).to eq(issue.iid)
    end

    it 'does not create a commit when content is byte-identical' do
      first_sha = service.execute([issue])

      expect(described_class.new(project).execute([issue.reload])).to be_nil
      expect(repository.commit(branch).sha).to eq(first_sha)
    end

    it 'stamps the commit with the app version as a git trailer' do
      allow(Gitlab).to receive(:revision).and_return('0.7.7-12-gabc1234')

      service.execute([issue])

      message = repository.commit(branch).message
      expect(message).to start_with("Sync work items\n\n")
      expect(message.lines.map(&:chomp)).to include('Unfurl-Cloud-Version: 0.7.7-12-gabc1234')
    end

    it 'stamps the instance that wrote the commit' do
      allow(Gitlab::CurrentSettings).to receive(:uuid).and_return('8f4a1e2b-6c3d-4f5a-9b7e-1d2c3a4b5c21')

      service.execute([issue])

      expect(repository.commit(branch).message).to include(
        "Unfurl-Cloud-Instance: 8f4a1e2b-6c3d-4f5a-9b7e-1d2c3a4b5c21 #{Gitlab.config.gitlab.url}")
    end

    # In the file it would make an upstream bump rewrite the whole branch; here
    # it costs nothing and `git log -1 -- issues/42.yml` still answers "which
    # export schema produced this file" exactly.
    it 'records the import/export schema version the records follow' do
      service.execute([issue])

      expect(repository.commit(branch).message)
        .to include("Work-Items-Export-Schema: #{Gitlab::ImportExport::VERSION}")
    end

    it 'claims no watermark for an incremental sync, which scanned nothing' do
      service.execute([issue])

      expect(repository.commit(branch).message).not_to include('Work-Items-Synced-Through')
    end

    it 'records the watermark a full pass supplies, and carries it forward' do
      scanned_at = Time.utc(2026, 1, 2, 3, 4, 5)
      described_class.new(project, synced_through: scanned_at).execute([issue])

      expect(repository.commit(branch).message).to include('Work-Items-Synced-Through: 2026-01-02T03:04:05Z')

      # An incremental sync afterwards scanned nothing, so it must neither
      # advance the watermark nor drop it -- dropping it would send the next
      # reconcile back to an unfiltered pass.
      issue.update!(title: 'changed by an incremental sync')
      described_class.new(project).execute([issue.reload])

      expect(repository.commit(branch).message).to include('Work-Items-Synced-Through: 2026-01-02T03:04:05Z')
    end

    # Same value the help page shows as "Current Version", unmodified -- a
    # trailer that disagreed with the version users can read off the UI would
    # not be much use for working out which build wrote a commit.
    it 'records the revision verbatim, as the help page does' do
      allow(Gitlab).to receive(:revision).and_return('release#12!3')

      service.execute([issue])

      expect(repository.commit(branch).message).to include('Unfurl-Cloud-Version: release#12!3')
    end

    it 'updates the existing file when the issue changed' do
      service.execute([issue])
      issue.update!(title: 'changed title')

      described_class.new(project).execute([issue.reload])

      expect(YAML.safe_load(sync_blob("issues/#{issue.iid}.yml").data)['title']).to eq('changed title')
    end

    it 'commits as the project owner with the acting user as git author' do
      acting_user = create(:user, name: 'Acting User')

      described_class.new(project, triggered_by: acting_user).execute([issue])

      commit = repository.commit(branch)
      expect(commit.author_name).to eq('Acting User')
      expect(commit.committer_name).to eq(project.first_owner.name)
    end

    it 'skips silently when the project has no owner' do
      allow(project).to receive(:first_owner).and_return(nil)

      expect(service.execute([issue])).to be_nil
      expect(repository.branch_exists?(branch)).to be(false)
    end

    it 'removes the file of an issue that became confidential on a public project' do
      public_project = create(:project, :public, :repository)
      public_issue = create(:issue, project: public_project)

      described_class.new(public_project).execute([public_issue])
      public_issue.update!(confidential: true)
      described_class.new(public_project).execute([public_issue.reload])

      sha = public_project.repository.commit(branch).sha
      expect(public_project.repository.blob_at(sha, sync_path("issues/#{public_issue.iid}.yml"))).to be_nil
    end
  end

  # A replica occupies the same path a document of ours would, so a third
  # instance fetching this branch learns the item exists here without it being
  # republished as though we owned it.
  describe 'a replica of another instance' do
    it 'commits a pointer at the source instead of the item' do
      create(:oc_replicated_work_item, project: project, issue: issue,
        source_path: 'peer-uuid/issues/42.yml',
        source_web_url: 'https://peer.example.com/g/p/-/issues/42')

      service.execute([issue.reload])

      data = YAML.safe_load(sync_blob("issues/#{issue.iid}.yml").data)
      expect(data['_schema']).to eq('issue_reference@1')
      expect(data['source_path']).to eq('peer-uuid/issues/42.yml')
      expect(data).not_to have_key('title')
    end

    it 'is not swept away as an orphan -- the local record is real' do
      create(:oc_replicated_work_item, project: project, issue: issue,
        source_path: 'peer-uuid/issues/42.yml')
      service.execute([issue.reload])

      described_class.new(project).remove_orphans

      expect(sync_blob("issues/#{issue.iid}.yml")).to be_present
    end
  end

  # A frozen item needs a third outcome, because writing nothing already means
  # deleting the file. Its document has to stay exactly as it is until the
  # instance taking it over publishes its own -- deleting it in the meantime
  # would withdraw the item from every instance mirroring it, for as long as
  # the transfer takes.
  describe 'an item being transferred away' do
    it 'leaves its document untouched rather than replacing or deleting it' do
      service.execute([issue])
      before = sync_blob("issues/#{issue.iid}.yml").data

      issue.update!(title: 'Edited after the freeze')
      create(:oc_replicated_work_item, :surrendered, project: project, issue: issue,
        source_iid: issue.iid)

      expect(described_class.new(project).execute([issue.reload])).to be_nil
      expect(sync_blob("issues/#{issue.iid}.yml").data).to eq(before)
    end
  end

  # A purge exists to make our own past content unreachable. Since the move to
  # per-instance directories the branch is not only ours, and a peer's
  # directory cannot be rebuilt from local records the way ours can.
  describe '#purge_own_history!' do
    let(:peer) { '11111111-2222-3333-4444-555555555555' }
    let(:peer_path) { "#{peer}/issues/42.yml" }

    def seed_peer(path = peer_path, content = "_schema: issues@1\ntitle: Theirs\n")
      repository.create_file(
        project.first_owner, path, content, message: 'peer push', branch_name: branch)
    end

    # Parentlessness rather than a changed sha: with nothing carried across,
    # the rebuild can produce a byte-identical orphan commit -- same tree, same
    # second -- and so the same sha. What actually has to be true is that no
    # earlier commit is reachable any more.
    it 'discards our history' do
      service.execute([issue])
      later = create(:issue, project: project)
      described_class.new(project).execute([later])
      expect(repository.commit(branch).parent_ids).not_to be_empty

      described_class.new(project).purge_own_history!
      described_class.new(project).execute([issue.reload, later.reload])

      expect(repository.commit(branch).parent_ids).to be_empty
    end

    it 'carries a peer directory across, byte for byte' do
      service.execute([issue])
      seed_peer
      content = repository.blob_at(repository.commit(branch).sha, peer_path).data

      described_class.new(project).purge_own_history!

      restored = repository.blob_at(repository.commit(branch).sha, peer_path)
      expect(restored).to be_present
      expect(restored.data).to eq(content)
    end

    # Everything that is not ours, rather than a list of peer directories: a
    # root-level file belongs to nobody in particular and would otherwise be
    # the thing someone forgets.
    it 'carries a root-level file across too' do
      service.execute([issue])
      seed_peer('transfers.yml', "_schema: transfers@1\n")

      described_class.new(project).purge_own_history!

      expect(repository.blob_at(repository.commit(branch).sha, 'transfers.yml')).to be_present
    end

    it 'still removes our own files' do
      service.execute([issue])
      seed_peer

      described_class.new(project).purge_own_history!

      expect(sync_blob("issues/#{issue.iid}.yml")).to be_nil
    end

    it 'deletes the branch outright when there was nothing of anyone else' do
      service.execute([issue])

      described_class.new(project).purge_own_history!

      expect(repository.branch_exists?(branch)).to be(false)
    end

    it 'no-ops when there is no branch' do
      expect(described_class.new(project).purge_own_history!).to be(false)
    end

    # The reason any of this matters: without it the next import run reads
    # every peer path as gone and deletes every replica in the project, over a
    # purely local confidentiality toggle.
    it 'leaves the next import run with nothing to delete' do
      service.execute([issue])
      seed_peer
      replica = create(:oc_replicated_work_item,
        project: project, issue: issue, source_instance_uuid: peer,
        source_path: peer_path,
        source_blob_oid: repository.blob_at(repository.commit(branch).sha, peer_path).id)

      described_class.new(project).purge_own_history!

      plan = OC::WorkItems::ImportReconciler.new(project.reload).plan(peer)
      expect(plan.select { |action| action.kind == :delete }).to be_empty
      expect(replica.reload.issue_id).to be_present
    end
  end

  describe '#execute_commit_notes' do
    let(:commit_id) { project.commit.sha }
    let(:path) { "commit_notes/#{commit_id}.yml" }

    def commit_note(body)
      create(:note_on_commit, project: project, commit_id: commit_id, note: body)
    end

    it 'writes one file per commit holding all of its notes' do
      commit_note('first')
      commit_note('second')

      described_class.new(project).execute_commit_notes([commit_id])

      data = YAML.safe_load(sync_blob(path).data)
      expect(data['commit_id']).to eq(commit_id)
      expect(data['notes'].pluck('note')).to contain_exactly('first', 'second')
    end

    it 'does not create a commit when content is byte-identical' do
      commit_note('first')
      first_sha = described_class.new(project).execute_commit_notes([commit_id])

      expect(described_class.new(project).execute_commit_notes([commit_id])).to be_nil
      expect(repository.commit(branch).sha).to eq(first_sha)
    end

    it 'deletes the file once the last note on the commit is gone' do
      note = commit_note('the only note')
      described_class.new(project).execute_commit_notes([commit_id])
      expect(sync_blob(path)).to be_present

      note.destroy!
      described_class.new(project).execute_commit_notes([commit_id])

      expect(sync_blob(path)).to be_nil
    end

    it 'no-ops for a commit that never had notes' do
      expect(described_class.new(project).execute_commit_notes([commit_id])).to be_nil
      expect(repository.branch_exists?(branch)).to be(false)
    end

    it 'writes several commits in a single commit to the branch' do
      other_commit_id = 'f0c7d1a94e3b6528d0b1f4a27c9e83b5d6a10f42'
      commit_note('on the first commit')
      create(:note_on_commit, project: project, commit_id: other_commit_id, note: 'on the second')

      described_class.new(project).execute_commit_notes([commit_id, other_commit_id])

      head = repository.commit(branch)
      expect(head.parent_ids).to be_empty
      expect(repository.blob_at(head.sha, sync_path(path))).to be_present
      expect(repository.blob_at(head.sha, sync_path("commit_notes/#{other_commit_id}.yml"))).to be_present
    end
  end

  describe '#execute_catalogs' do
    def catalog(basename)
      blob = sync_blob(basename)
      blob && YAML.safe_load(blob.data)
    end

    it 'writes the project label and milestone catalogs' do
      create(:label, project: project, title: 'bug')
      create(:milestone, project: project, title: '15.11')

      described_class.new(project).execute_catalogs

      expect(catalog('labels.yml')['labels'].pluck('title')).to contain_exactly('bug')
      expect(catalog('milestones.yml')['milestones'].pluck('title')).to contain_exactly('15.11')
    end

    # The point of the catalogs: an unused label or an empty milestone exists
    # nowhere else on the branch, because the per-record files only carry what
    # a work item actually references.
    it 'includes labels and milestones no work item uses' do
      create(:label, project: project, title: 'never-applied')
      create(:milestone, project: project, title: 'empty-milestone')

      described_class.new(project).execute_catalogs

      expect(catalog('labels.yml')['labels'].pluck('title')).to include('never-applied')
      expect(catalog('milestones.yml')['milestones'].pluck('title')).to include('empty-milestone')
    end

    context 'in a nested group' do
      let(:parent) { create(:group) }
      let(:subgroup) { create(:group, parent: parent) }
      let(:project) { create(:project, :repository, group: subgroup) }

      # A group project has no owner of its own; sync commits as the group's,
      # and a group with no members has none at all.
      before do
        parent.add_owner(create(:user))
      end

      it 'includes every ancestor group, not just the immediate one' do
        create(:group_label, group: parent, title: 'from-parent')
        create(:group_label, group: subgroup, title: 'from-subgroup')
        create(:label, project: project, title: 'from-project')
        create(:milestone, group: parent, title: 'parent-milestone')

        described_class.new(project).execute_catalogs

        labels = catalog('labels.yml')['labels']
        expect(labels.pluck('title')).to contain_exactly('from-parent', 'from-subgroup', 'from-project')
        inherited = labels.find { |l| l['title'] == 'from-parent' }
        expect(inherited).to include('type' => 'GroupLabel', 'group_id' => parent.id)
        # Not present-and-null: a key with nothing in it is left out entirely.
        expect(inherited).not_to have_key('project_id')

        expect(catalog('milestones.yml')['milestones'].pluck('title')).to include('parent-milestone')
      end

      # A group label's priorities span every project that prioritised it;
      # only this project's belong in this project's repository.
      it 'keeps only this project\'s priorities on an inherited label' do
        group_label = create(:group_label, group: parent, title: 'shared')
        other_project = create(:project, group: subgroup)
        create(:label_priority, project: project, label: group_label, priority: 1)
        create(:label_priority, project: other_project, label: group_label, priority: 2)

        described_class.new(project).execute_catalogs

        priorities = catalog('labels.yml')['labels'].find { |l| l['title'] == 'shared' }['priorities']
        expect(priorities.pluck('project_id')).to contain_exactly(project.id)
      end
    end

    it 'does not create a commit when the catalogs are unchanged' do
      create(:label, project: project, title: 'bug')
      first_sha = described_class.new(project).execute_catalogs

      expect(described_class.new(project).execute_catalogs).to be_nil
      expect(repository.commit(branch).sha).to eq(first_sha)
    end

    it 'deletes a catalog once its last record is gone' do
      label = create(:label, project: project, title: 'bug')
      described_class.new(project).execute_catalogs
      expect(sync_blob('labels.yml')).to be_present

      label.destroy!
      described_class.new(project).execute_catalogs

      expect(sync_blob('labels.yml')).to be_nil
    end

    it 'no-ops for a project with no labels or milestones' do
      expect(described_class.new(project).execute_catalogs).to be_nil
      expect(repository.branch_exists?(branch)).to be(false)
    end
  end

  # ids.yml resolves the database ids the other files carry. It is a file of
  # its own rather than a header in each document precisely so that a rename --
  # of a user, a project, a group -- rewrites one file instead of every file
  # that mentions the renamed thing.
  describe 'ids.yml' do
    def committed_ids
      YAML.safe_load(sync_blob('ids.yml').data)
    end

    it 'rides along in the commit that introduced the ids' do
      sha = service.execute([issue])

      expect(repository.commit(branch).sha).to eq(sha)
      expect(committed_ids['_schema']).to eq('ids@1')
      expect(committed_ids['projects']).to eq(project.id => project.full_path)
      expect(committed_ids['users'][issue.author_id])
        .to include('username' => issue.author.username, 'name' => issue.author.name)
    end

    it 'adds to what is already committed instead of replacing it' do
      service.execute([issue])
      other = create(:issue, project: project, author: create(:user))

      described_class.new(project).execute([other])

      expect(committed_ids['users'].keys).to contain_exactly(issue.author_id, other.author_id)
    end

    # The documents serialize to the bytes they already had, so this commit
    # exists only to carry the new name -- which is the whole point of keeping
    # the map out of them.
    it 'picks up a rename even though no document changed' do
      service.execute([issue])

      issue.author.update!(username: 'renamed-since')

      expect(described_class.new(project).execute([issue.reload])).to be_present
      expect(committed_ids['users'][issue.author_id]['username']).to eq('renamed-since')
    end

    it 'writes nothing of its own when the ids are unchanged' do
      head = service.execute([issue])

      expect(described_class.new(project).execute([issue.reload])).to be_nil
      expect(repository.commit(branch).sha).to eq(head)
    end

    # An unfiltered pass has just walked every document on the branch, so what
    # it holds is the whole truth and can replace the file rather than add to
    # it. Incremental passes have seen only what they touched and must not.
    it 'is rebuilt by a full pass, dropping ids nothing refers to any more' do
      departed = create(:issue, project: project, author: create(:user))
      service.execute([issue, departed])
      expect(committed_ids['users'].keys).to include(departed.author_id)

      departed.destroy!

      full_pass = described_class.new(project)
      full_pass.execute(project.issues)
      full_pass.execute_catalogs

      expect(committed_ids['users'].keys).to contain_exactly(issue.author_id)
    end

    it 'is left alone by a pass that read a file it does not recognise' do
      service.execute([issue])
      repository.update_file(
        project.first_owner, sync_path('ids.yml'), "_schema: something-else@9\n",
        message: 'seed', branch_name: branch)

      described_class.new(project).execute([create(:issue, project: project)])

      expect(committed_ids['_schema']).to eq('ids@1')
      expect(committed_ids['users']).to be_present
    end

    it 'refuses to rewrite a file it could only read part of' do
      service.execute([issue])
      allow_next_instance_of(Blob) do |blob|
        allow(blob).to receive(:truncated?).and_return(true)
      end

      expect { described_class.new(project).execute([issue.reload]) }
        .to raise_error(described_class::IdentitiesTruncatedError)
    end
  end

  describe '#remove_orphans' do
    it 'deletes files whose records no longer exist and keeps the rest' do
      service.execute([issue])
      repository.create_file(
        project.first_owner, sync_path('issues/9999.yml'), "gone: true\n",
        message: 'seed orphan', branch_name: branch)

      described_class.new(project).remove_orphans

      head = repository.commit(branch).sha
      expect(repository.blob_at(head, sync_path('issues/9999.yml'))).to be_nil
      expect(repository.blob_at(head, sync_path("issues/#{issue.iid}.yml"))).to be_present
    end

    # A peer instance's directory looks exactly like an orphan from here --
    # every file in it names a record this project does not have. Sweeping it
    # would delete the entire contents of another instance's sync.
    it 'leaves another instance directory alone' do
      service.execute([issue])
      peer_path = "11111111-2222-3333-4444-555555555555/issues/1.yml"
      repository.create_file(
        project.first_owner, peer_path, "peer: true\n",
        message: 'seed peer', branch_name: branch)

      described_class.new(project).remove_orphans

      expect(repository.blob_at(repository.commit(branch).sha, peer_path)).to be_present
    end

    it 'treats files of merge requests from the sync branch as orphans' do
      service.execute([issue])
      merge_request = create(:merge_request, source_project: project, target_project: project)
      repository.create_file(
        project.first_owner, sync_path("merge_requests/#{merge_request.iid}.yml"), "stale: true\n",
        message: 'seed', branch_name: branch)
      merge_request.update_columns(source_branch: branch)

      described_class.new(project).remove_orphans

      head = repository.commit(branch).sha
      expect(repository.blob_at(head, sync_path("merge_requests/#{merge_request.iid}.yml"))).to be_nil
    end

    # A commit notes file is an orphan when its notes are gone, not when its
    # commit is: notes outlive a force-push, and the rows are what the branch
    # mirrors.
    it 'deletes commit notes files whose notes are gone, keeping the rest' do
      commit_id = project.commit.sha
      create(:note_on_commit, project: project, commit_id: commit_id, note: 'still here')
      described_class.new(project).execute_commit_notes([commit_id])

      stale_sha = 'f0c7d1a94e3b6528d0b1f4a27c9e83b5d6a10f42'
      repository.create_file(
        project.first_owner, sync_path("commit_notes/#{stale_sha}.yml"), "gone: true\n",
        message: 'seed orphan', branch_name: branch)

      described_class.new(project).remove_orphans

      head = repository.commit(branch).sha
      expect(repository.blob_at(head, sync_path("commit_notes/#{stale_sha}.yml"))).to be_nil
      expect(repository.blob_at(head, sync_path("commit_notes/#{commit_id}.yml"))).to be_present
    end

    # The catalogs and ids.yml live at the branch root and belong to no
    # per-record relation, so nothing about them looks like a record whose row
    # went away.
    it 'never treats the branch-root files as orphans' do
      create(:label, project: project, title: 'bug')
      service.execute([issue])
      described_class.new(project).execute_catalogs

      described_class.new(project).remove_orphans

      expect(sync_blob('labels.yml')).to be_present
      expect(sync_blob('ids.yml')).to be_present
    end

    it 'no-ops when the branch does not exist' do
      expect(service.remove_orphans).to be_nil
      expect(repository.branch_exists?(branch)).to be(false)
    end

    it 'does not commit when there are no orphans' do
      service.execute([issue])
      head = repository.commit(branch).sha

      described_class.new(project).remove_orphans

      expect(repository.commit(branch).sha).to eq(head)
    end
  end

  describe '#remove' do
    it 'deletes the file for a destroyed issuable' do
      service.execute([issue])
      iid = issue.iid
      issue.destroy!

      described_class.new(project).remove('Issue', iid)

      expect(sync_blob("issues/#{iid}.yml")).to be_nil
    end

    # The reason this guard exists. Callers land here having failed to find the
    # record by id, and an import applies an update by rebuilding: it destroys
    # the record and creates another carrying the same iid. Acting on the id
    # alone would delete the file belonging to the record that is now live.
    it 'keeps the file when a record still holds that iid' do
      service.execute([issue])

      described_class.new(project).remove('Issue', issue.iid)

      expect(sync_blob("issues/#{issue.iid}.yml")).to be_present
    end

    it 'still removes a file whose issuable moved to another project' do
      service.execute([issue])
      iid = issue.iid
      issue.update_columns(project_id: create(:project).id)

      described_class.new(project).remove('Issue', iid)

      expect(sync_blob("issues/#{iid}.yml")).to be_nil
    end

    it 'no-ops when the branch does not exist' do
      expect(service.remove('Issue', 12345)).to be_nil
      expect(repository.branch_exists?(branch)).to be(false)
    end
  end

  describe '#delete_branch!' do
    it 'removes the branch and everything in its history' do
      service.execute([issue])
      old_sha = repository.commit(branch).sha

      expect(described_class.new(project).delete_branch!).to be(true)

      expect(repository.branch_exists?(branch)).to be(false)
      expect(repository.commit(branch)).to be_nil
      # the old commit is no longer reachable from any branch
      expect(repository.branch_names).not_to include(branch)
      expect(old_sha).to be_present
    end

    it 'returns false when there is no branch' do
      expect(service.delete_branch!).to be(false)
    end

    it 'lets a following sync rebuild the branch with no history behind it' do
      # Two commits, so the branch has a history to lose. The first one holds
      # the original title -- the stand-in here for content that must stop
      # being readable.
      service.execute([issue])
      issue.update!(title: 'title after the first commit')
      described_class.new(project).execute([issue.reload])

      history = repository.commits(branch, limit: 10)
      expect(history.size).to eq(2)
      superseded_sha = history.last.sha

      described_class.new(project).delete_branch!
      described_class.new(project).execute([issue.reload])

      rebuilt = repository.commit(branch)
      expect(rebuilt.parent_ids).to be_empty
      expect(repository.commits(branch, limit: 10).size).to eq(1)
      expect(repository.commits(branch, limit: 10).map(&:sha)).not_to include(superseded_sha)
      expect(YAML.safe_load(sync_blob("issues/#{issue.iid}.yml").data)['title'])
        .to eq('title after the first commit')
    end
  end
end
