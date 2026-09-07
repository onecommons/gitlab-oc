# frozen_string_literal: true

require 'spec_helper'

# One instance's work items, all the way onto a branch and back off it into
# another instance.
#
# Every other spec here feeds the importer YAML written by hand, which means
# none of them would notice the serializer and the importer drifting apart --
# a key renamed on the way out and still read by the old name on the way in
# would pass every one of them. This is the only test where the bytes the
# writer produces are the bytes the reader consumes.
#
# Two instances are simulated by stubbing the instance uuid, which is the only
# thing that distinguishes them: it names the directory each writes under and
# is how each recognises the other's files as somebody else's.
RSpec.describe 'work items import end to end', feature_category: :source_code_management do
  let_it_be(:author) { create(:user, :with_namespace, username: 'remote-author', name: 'Remote Author') }

  let(:instance_a) { 'aaaaaaaa-1111-2222-3333-444444444444' }
  let(:instance_b) { 'bbbbbbbb-5555-6666-7777-888888888888' }
  let(:branch) { OC::WorkItems::SYNC_BRANCH }

  # let, not let_it_be: repositories are Gitaly state and do not roll back.
  let(:source) { create(:project, :repository, namespace: author.namespace) }
  let(:target) { create(:project, :repository) }

  def as_instance(uuid)
    allow(::Gitlab::CurrentSettings).to receive(:uuid).and_return(uuid)
    yield
  end

  def branch_contents(project)
    sha = project.repository.commit(branch).sha

    project.repository.tree(sha, nil, recursive: true).entries
      .select { |entry| entry.type == :blob }
      .to_h { |entry| [entry.path, project.repository.blob_at(sha, entry.path).tap(&:load_all_data!).data] }
  end

  # What ImportWorker does for a push: every peer directory on the branch,
  # asked for deliberately, because an Owner pushed it and that is the gate.
  def import_all(project)
    OC::WorkItems::ImportRunService.new(project).execute(directories: nil)
  end

  # Importing is opt-in per relationship, so the branch has to carry a
  # declaration saying B takes A's items. A needs none of its own: it is only
  # being read, and nothing about being read is A's to allow.
  def declaring(files)
    files.merge(OC::WorkItems::SyncFile::PATH => <<~YAML)
      ---
      _schema: sync@1
      a:
        uuid: #{instance_a}
      b:
        uuid: #{instance_b}
        sync:
          a:
            import: all
    YAML
  end

  # What a `git push` of the branch amounts to, content-wise.
  def push_to(project, files)
    project.repository.commit_files(
      project.first_owner,
      branch_name: branch,
      message: 'peer push',
      actions: files.map { |path, content| { action: :create, file_path: path, content: content } })
  end

  # Instance A: two issues, one naming the other, with a label and a comment.
  def publish_source
    as_instance(instance_a) do
      source.enable_work_items_sync!(true)

      referenced = create(:labeled_issue, project: source, author: author,
        title: 'Referenced', labels: [create(:label, project: source, title: 'bug')])
      referrer = create(:issue, project: source, author: author, title: 'Referrer',
        description: "blocked by ##{referenced.iid}, ask @remote-author")
      create(:note, noteable: referrer, project: source, author: author, note: 'A comment.')

      OC::WorkItems::FullSyncWorker.new.perform(source.id)

      [referrer.iid, referenced.iid, branch_contents(source)]
    end
  end

  it 'carries items between instances, and settles' do
    referrer_iid, referenced_iid, files = publish_source

    expect(files.keys).to include(
      "#{instance_a}/issues/#{referrer_iid}.yml",
      "#{instance_a}/ids.yml")

    as_instance(instance_b) do
      # Occupy the numbers the source used. Two instances syncing their own
      # items to one branch is the ordinary case, so a collision is ordinary
      # too -- and it is what makes the reference rewriting below mean
      # anything. With the numbers preserved, `#2` rewrites to `#2` and the
      # assertion would hold however broken the rewriting was.
      create_list(:issue, 3, project: target)

      push_to(target, declaring(files))

      import_all(target)

      rows = OC::WorkItems::ReplicatedWorkItem.where(project_id: target.id)
      referrer = rows.find_by(source_iid: referrer_iid).issue
      referenced = rows.find_by(source_iid: referenced_iid).issue

      expect([referrer.title, referenced.title]).to contain_exactly('Referrer', 'Referenced')

      # Numbers of their own, because the source's were taken.
      expect(referrer.iid).not_to eq(referrer_iid)
      expect(referenced.iid).not_to eq(referenced_iid)

      # Written by the serializer, read by the importer, resolved through the
      # replica rows: the reference follows the local number.
      expect(referrer.description).to include("blocked by ##{referenced.iid}")
      expect(referrer.description).not_to include("blocked by ##{referenced_iid}")

      # The author did not map -- identity trust is off -- so the item is the
      # ghost user's, and says whose it really was.
      expect(referrer.author).to eq(Users::Internal.in_organization(target.organization).ghost)
      expect(referrer.description).to include('*By Remote Author')

      # The mention links out rather than resolving to whoever holds that name
      # here.
      expect(referrer.description).to include('[@remote-author](')

      # The comment came too.
      expect(referrer.notes.map(&:note)).to include(a_string_including('A comment.'))

      # And the label, found or created by ObjectBuilder.
      expect(referenced.labels.map(&:title)).to include('bug')

      # Read-only, for the person with the most rights on the project.
      expect(Ability.allowed?(target.first_owner, :read_issue, referrer)).to be(true)
      expect(Ability.allowed?(target.first_owner, :update_issue, referrer)).to be(false)
      expect(Ability.allowed?(target.first_owner, :create_note, referrer)).to be(false)

      # Importing turned sync on, so this project maintains its own files.
      expect(target.reload.work_items_sync_enabled?).to be(true)
    end
  end

  it 'publishes pointers rather than republishing what it does not own' do
    _, _, files = publish_source

    as_instance(instance_b) do
      push_to(target, declaring(files))
      import_all(target)

      OC::WorkItems::FullSyncWorker.new.perform(target.id)

      contents = branch_contents(target)
      ours = contents.select { |path, _| path.start_with?("#{instance_b}/issues/") }

      expect(ours).to be_present
      ours.each_value do |body|
        document = YAML.safe_load(body)
        expect(document['_schema']).to eq('issue_reference@1')
        expect(document['source_path']).to start_with("#{instance_a}/issues/")
        expect(document).not_to have_key('title')
      end

      # A's directory is still there, untouched -- we mirror it, we do not own
      # it, and we do not delete it either.
      expect(contents.keys).to include("#{instance_a}/ids.yml")
    end
  end

  it 'changes nothing on a second run over an unchanged branch' do
    _, _, files = publish_source

    as_instance(instance_b) do
      push_to(target, declaring(files))
      import_all(target)
      OC::WorkItems::FullSyncWorker.new.perform(target.id)

      ids = target.issues.reload.map(&:id).sort
      head = target.repository.commit(branch).sha

      import_all(target)
      OC::WorkItems::FullSyncWorker.new.perform(target.id)

      expect(target.issues.reload.map(&:id).sort).to eq(ids)
      expect(target.repository.commit(branch).sha).to eq(head)
    end
  end

  # The receiving project has to go on being a project afterwards.
  #
  # has_internal_id skips its tracking callback while importing, so numbers
  # kept from the source leave the project's counter behind them. The next
  # issue anyone files is handed a number the import already took, the insert
  # fails on the unique index, and the rollback reverts the counter increment
  # with it -- so the retry produces the same number and fails again. The
  # project stops being able to create issues at all.
  it 'leaves the receiving project able to number its own issues' do
    referrer_iid, referenced_iid, files = publish_source

    as_instance(instance_b) do
      # The project needs a counter of its own, sitting below the numbers
      # about to arrive. Without this the assertion is vacuous: on a project
      # that has never filed an issue there is no counter row yet, and
      # has_internal_id's `init:` seeds it from max(iid) -- which quietly
      # papers over exactly the gap being tested. Filing one and deleting it
      # leaves the counter at 1 with both numbers free.
      create(:issue, project: target).destroy!

      push_to(target, declaring(files))
      import_all(target)

      # Both numbers were free, so both were kept -- the path where the
      # counter has to be told.
      expect(target.issues.reload.map(&:iid)).to contain_exactly(referrer_iid, referenced_iid)

      local = nil
      expect { local = create(:issue, project: target) }.not_to raise_error
      expect(local.iid).to be > [referrer_iid, referenced_iid].max
    end
  end

  it 'brings an edit across on the next push, and drops what was deleted' do
    referrer_iid, referenced_iid, files = publish_source

    as_instance(instance_b) do
      push_to(target, declaring(files))
      import_all(target)

      # Nothing local held these, so here the source's numbers are kept -- the
      # other half of the rule the first example exercises.
      expect(target.issues.reload.map(&:iid)).to contain_exactly(referrer_iid, referenced_iid)
    end

    edited = as_instance(instance_a) do
      source.issues.find_by(iid: referrer_iid).update!(title: 'Referrer, edited')
      source.issues.find_by(iid: referenced_iid).destroy!
      OC::WorkItems::FullSyncWorker.new.perform(source.id)
      branch_contents(source)
    end

    as_instance(instance_b) do
      target.repository.delete_refs("refs/heads/#{branch}")
      target.repository.expire_branches_cache
      push_to(target, declaring(edited))

      import_all(target)

      expect(target.issues.reload.map(&:title)).to contain_exactly('Referrer, edited')
      expect(OC::WorkItems::ReplicatedWorkItem.where(project_id: target.id).count).to eq(1)
    end
  end
end
