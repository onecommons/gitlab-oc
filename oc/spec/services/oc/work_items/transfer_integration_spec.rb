# frozen_string_literal: true

require 'spec_helper'

# Ownership moving between two installations, all the way through.
#
# Every scenario here is a property of the *interaction* of freezing,
# taking and letting go across separate runs and separate pushes, which no
# single transition's spec can witness. The transitions are unit-tested
# elsewhere; what is tested here is that they compose -- including the ones
# where a standing declaration keeps naming an item long after it has moved,
# which is the ordinary state of a file nobody has tidied up.
#
# Two installations are simulated by stubbing the instance uuid, which is the
# only thing that distinguishes them, and by carrying the branch between two
# projects by hand -- which is exactly what pushing it does.
RSpec.describe 'work items ownership transfer', feature_category: :source_code_management do
  let(:staging_uuid) { 'aaaaaaaa-1111-2222-3333-444444444444' }
  let(:prod_uuid) { 'bbbbbbbb-5555-6666-7777-888888888888' }
  let(:branch) { OC::WorkItems::SYNC_BRANCH }

  # let, not let_it_be: repositories are Gitaly state and do not roll back.
  let(:staging) { create(:project, :repository) }
  let(:prod) { create(:project, :repository) }

  def as_instance(uuid)
    allow(::Gitlab::CurrentSettings).to receive(:uuid).and_return(uuid)
    yield
  end

  def contents(project)
    sha = project.repository.commit(branch)&.sha
    return {} unless sha

    project.repository.tree(sha, nil, recursive: true).entries
      .select { |entry| entry.type == :blob }
      .to_h { |entry| [entry.path, project.repository.blob_at(sha, entry.path).tap(&:load_all_data!).data] }
  end

  # What a `git push` of the branch amounts to, content-wise. Files the other
  # side does not have are created, changed ones updated, and identical ones
  # left alone -- a push with nothing in it is not a commit.
  def push_to(project, files)
    existing = contents(project)

    actions = files.filter_map do |path, content|
      next if existing[path] == content

      { action: existing.key?(path) ? :update : :create, file_path: path, content: content }
    end
    return if actions.empty?

    project.repository.commit_files(
      project.first_owner, branch_name: branch, message: 'peer push', actions: actions)
  end

  # A push arriving: import what the branch now says, then publish whatever
  # that made this project responsible for.
  def receive_push(project, uuid, initiate: true)
    as_instance(uuid) do
      OC::WorkItems::ImportRunService.new(project)
        .execute(directories: nil, initiate_transfers: initiate)

      OC::WorkItems::FullSyncWorker.new.perform(project.id)
    end
  end

  def publish(project, uuid)
    as_instance(uuid) do
      project.enable_work_items_sync!(true)
      OC::WorkItems::FullSyncWorker.new.perform(project.id)
    end
  end

  def sync_file(staging_sync: nil, prod_sync: nil)
    {
      OC::WorkItems::SyncFile::PATH => <<~YAML
        ---
        _schema: sync@1
        staging:
          uuid: #{staging_uuid}
        #{staging_sync}
        prod:
          uuid: #{prod_uuid}
        #{prod_sync}
      YAML
    }
  end

  # staging gives everything to prod; prod takes only what it is given.
  def migration_file
    sync_file(
      staging_sync: "  sync:\n    prod:\n      transfer: all",
      prod_sync: "  sync:\n    staging:\n      import: transferred")
  end

  def rows(project)
    OC::WorkItems::ReplicatedWorkItem.where(project_id: project.id)
  end

  def issue_on(project, title)
    project.issues.reload.find_by(title: title)
  end

  # An issue on staging, published to its branch.
  def start_with(title)
    issue = as_instance(staging_uuid) { create(:issue, project: staging, title: title) }
    publish(staging, staging_uuid)
    issue
  end

  # staging freezes and publishes; the branch travels; prod imports, takes it
  # and publishes; the branch travels back; staging lets go.
  def hand_over(files = migration_file)
    push_to(staging, files)
    receive_push(staging, staging_uuid)

    push_to(prod, contents(staging))
    receive_push(prod, prod_uuid)

    push_to(staging, contents(prod))
    receive_push(staging, staging_uuid)
  end

  describe 'a plain transfer' do
    let!(:issue) { start_with('Fix the deploy') }

    before do
      hand_over
    end

    it 'leaves the item editable on the instance that took it' do
      taken = issue_on(prod, 'Fix the deploy')

      expect(taken).to be_present
      expect(Ability.allowed?(prod.first_owner, :update_issue, taken)).to be(true)
      expect(rows(prod).first).to be_state_adopted
    end

    # The whole point of pinning the number: every link anyone ever wrote to
    # this issue still resolves to it.
    it 'leaves a read-only copy behind, under the number it always had' do
      here = staging.issues.reload.first

      expect(here.iid).to eq(issue.iid)
      expect(Ability.allowed?(staging.first_owner, :update_issue, here)).to be(false)
      expect(rows(staging).first).to have_attributes(
        state: 'imported', source_instance_uuid: prod_uuid)
    end

    # The document and the pointer swap places, at the paths they already
    # occupied, so nothing is left over anywhere.
    it 'swaps the document and the pointer' do
      ours = contents(staging)["#{staging_uuid}/issues/#{issue.iid}.yml"]
      theirs = contents(prod)["#{prod_uuid}/issues/#{issue_on(prod, 'Fix the deploy').iid}.yml"]

      expect(YAML.safe_load(ours)['_schema']).to eq('issue_reference@1')
      expect(YAML.safe_load(theirs)).to include(
        '_schema' => 'issues@1', 'transferred_from' => "#{staging_uuid}/issues/#{issue.iid}.yml")
    end

    it 'follows the new owner edits from then on' do
      as_instance(prod_uuid) do
        issue_on(prod, 'Fix the deploy').update!(title: 'Fix the deploy, properly')
        OC::WorkItems::FullSyncWorker.new.perform(prod.id)
      end

      push_to(staging, contents(prod))
      receive_push(staging, staging_uuid)

      expect(staging.issues.reload.map(&:title)).to contain_exactly('Fix the deploy, properly')
    end

    # The declaration still names the item, on both sides, for ever.
    it 'changes nothing however many more times the same file is pushed' do
      # One more exchange first: the pointer staging writes when it lets go has
      # to reach prod before the branches have finished agreeing.
      hand_over
      before_state = [contents(staging), contents(prod)]

      2.times { hand_over }

      expect([contents(staging), contents(prod)]).to eq(before_state)
      expect(rows(staging).first).to be_state_imported
      expect(rows(prod).first).to be_state_adopted
      expect([staging.issues.reload.count, prod.issues.reload.count]).to eq([1, 1])
    end
  end

  # The instance losing the item does not have to hear about it first. It can
  # be pushed to second, days later, or never -- what it must not do is import
  # the new owner's document as a second copy of an item it still holds.
  describe 'when the new owner is pushed to first' do
    let!(:issue) { start_with('Ordered the other way') }

    it 'waits, then finishes when the declaration arrives' do
      push_to(prod, contents(staging).merge(migration_file))
      receive_push(prod, prod_uuid)

      # Everything prod has, but not the declaration: this instance has not
      # been told anything yet.
      push_to(staging, contents(prod).except(OC::WorkItems::SyncFile::PATH))
      receive_push(staging, staging_uuid)

      expect(staging.issues.reload.map(&:title)).to contain_exactly('Ordered the other way')
      expect(Ability.allowed?(staging.first_owner, :update_issue, staging.issues.first)).to be(true)

      push_to(staging, contents(prod))
      receive_push(staging, staging_uuid)

      expect(staging.issues.reload.count).to eq(1)
      expect(rows(staging).first).to be_state_imported
    end
  end

  # Freezing runs before the reconcile precisely so that this works.
  describe 'when one push carries the declaration and the new owner document' do
    let!(:issue) { start_with('All at once') }

    it 'freezes and finishes in a single run' do
      push_to(prod, contents(staging).merge(migration_file))
      receive_push(prod, prod_uuid)

      push_to(staging, contents(prod))
      receive_push(staging, staging_uuid)

      expect(rows(staging).first).to be_state_imported
      expect(staging.issues.reload.first.iid).to eq(issue.iid)
    end
  end

  describe 'a run that dies between freezing and finishing' do
    let!(:issue) { start_with('Interrupted') }

    before do
      push_to(staging, migration_file)
      receive_push(staging, staging_uuid)

      push_to(prod, contents(staging))
      receive_push(prod, prod_uuid)

      push_to(staging, contents(prod))
    end

    # The nightly may finish a transfer, because a surrendered row is itself
    # the record that an authorized run started it.
    it 'is finished by the nightly, which never started it' do
      as_instance(staging_uuid) do
        OC::WorkItems::ImportRefreshWorker.new.perform(staging.id)
      end

      expect(rows(staging).first).to be_state_imported
    end

    # And the other half: a declaration pushed by somebody who may not
    # authorize one gets no help from the cron.
    it 'never starts one from the nightly alone' do
      other = create(:issue, project: staging, title: 'Not promised by an owner')
      publish(staging, staging_uuid)

      as_instance(staging_uuid) do
        OC::WorkItems::ImportRefreshWorker.new.perform(staging.id)
      end

      expect(other.reload.oc_replica).to be_nil
    end
  end

  # Both directions at once, over different items. The two flows touch
  # disjoint paths and both complete -- and then the item that arrived here
  # sits inside a `transfer: all` that goes on naming it, which is the
  # ordinary state of a declaration nobody has tidied up.
  describe 'items moving in both directions' do
    def declarations(prod_gives = nil)
      sync_file(
        staging_sync: "  sync:\n    prod:\n      transfer: all\n      import: transferred",
        prod_sync: "  sync:\n    staging:\n      import: transferred#{prod_gives}")
    end

    it 'completes both, and then leaves the arrived item alone for ever' do
      start_with('Staging gives this')
      theirs = as_instance(prod_uuid) { create(:issue, project: prod, title: 'Prod gives this') }
      publish(prod, prod_uuid)

      both = declarations("\n      transfer:\n        - issues/#{theirs.iid}.yml")

      # Four pushes: each side freezes and publishes, then each takes what it
      # was given and publishes, then each lets go of what it gave.
      3.times do
        push_to(staging, contents(prod).merge(both))
        receive_push(staging, staging_uuid)
        push_to(prod, contents(staging))
        receive_push(prod, prod_uuid)
      end

      # Each instance ends up owning exactly the item the other gave it, and
      # holding a copy of the one it gave away.
      expect(issue_on(prod, 'Staging gives this').oc_replica).to be_state_adopted
      expect(issue_on(staging, 'Prod gives this').oc_replica).to be_state_adopted
      expect(staging.issues.reload.count).to eq(2)
      expect(prod.issues.reload.count).to eq(2)

      # The ratchet: staging's `transfer: all` still names the item prod gave
      # it, and must never hand it back.
      arrived = issue_on(staging, 'Prod gives this')
      expect(Ability.allowed?(staging.first_owner, :update_issue, arrived)).to be(true)

      3.times do
        push_to(staging, contents(prod).merge(both))
        receive_push(staging, staging_uuid)
        push_to(prod, contents(staging))
        receive_push(prod, prod_uuid)
      end

      expect(issue_on(staging, 'Prod gives this').oc_replica).to be_state_adopted
      expect(Ability.allowed?(staging.first_owner, :update_issue, arrived.reload)).to be(true)
    end
  end

  # `transfer: all` is standing intent, not a snapshot of what existed when it
  # was written. An item filed afterwards drains through as well -- which is
  # what makes it usable for emptying an installation, and worth saying out
  # loud in the docs.
  describe 'an item filed after the declaration landed' do
    it 'drains through on the runs that follow' do
      start_with('First')
      hand_over

      as_instance(staging_uuid) { create(:issue, project: staging, title: 'Second') }
      publish(staging, staging_uuid)
      hand_over

      expect(prod.issues.reload.map(&:title)).to contain_exactly('First', 'Second')
      expect(rows(staging).map(&:state)).to eq(%w[imported imported])
    end
  end

  # The scenario the whole containment story is for: staging began as a copy of
  # production, database included, so production already has native records of
  # everything staging is about to hand back.
  describe 'a staging instance that began as a clone' do
    let(:shared_created_at) { Time.zone.parse('2026-01-02T03:04:05.000Z') }

    it 'settles without creating or destroying anything on the receiving side' do
      # The same issue on both, as a database copy leaves it: same number, same
      # creation instant.
      shared = as_instance(staging_uuid) do
        create(:issue, project: staging, title: 'Shared', created_at: shared_created_at)
      end
      as_instance(prod_uuid) do
        create(:issue, project: prod, title: 'Shared', iid: shared.iid,
          created_at: shared_created_at)
      end
      as_instance(staging_uuid) { create(:issue, project: staging, title: 'Only on staging') }

      publish(staging, staging_uuid)
      publish(prod, prod_uuid)

      native_ids = prod.issues.reload.map(&:id)

      hand_over

      # The shared item was recognised rather than copied, and then taken --
      # no second copy of it exists anywhere on prod.
      taken = issue_on(prod, 'Shared')
      expect(prod.issues.reload.map(&:title)).to contain_exactly('Shared', 'Only on staging')
      expect(native_ids).to include(taken.id)
      expect(rows(prod).map(&:state)).to match_array(%w[adopted adopted])

      # And staging ends up holding copies of both, through a block that
      # declares no import at all.
      expect(rows(staging).map(&:state)).to match_array(%w[imported imported])
      expect(staging.issues.reload.map(&:title)).to contain_exactly('Shared', 'Only on staging')
    end
  end
end
