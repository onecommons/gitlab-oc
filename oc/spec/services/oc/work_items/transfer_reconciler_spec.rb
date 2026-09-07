# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../support/helpers/work_item_sync_paths'

RSpec.describe OC::WorkItems::TransferReconciler, feature_category: :source_code_management do
  include WorkItemSyncPaths

  # let, not let_it_be: the repository is Gitaly state and does not roll back
  # with the database, so a shared project would carry one example's seeded
  # files into the next.
  let(:project) { create(:project, :repository) }
  let(:peer) { '11111111-2222-3333-4444-555555555555' }
  let(:branch) { OC::WorkItems::SYNC_BRANCH }

  # Files are put on the branch directly. Nothing here reads a document or
  # touches a record -- the whole point of the split is that what the branch
  # asks for can be worked out without either.
  def seed(path, content = "_schema: issues@1\n")
    project.repository.create_file(
      project.first_owner, path, content, message: 'seed', branch_name: branch)
  end

  def sha
    project.repository.commit(branch)&.sha
  end

  def reconciler(yaml)
    described_class.new(project, OC::WorkItems::SyncFile.parse(yaml))
  end

  # us gives, peer takes.
  def giving(transfer)
    <<~YAML
      ---
      _schema: sync@1
      us:
        uuid: #{OC::WorkItems.instance_directory}
        sync:
          them:
            transfer: #{transfer}
      them:
        uuid: #{peer}
        sync:
          us:
            import: transferred
    YAML
  end

  # peer gives, us takes.
  def taking(transfer)
    <<~YAML
      ---
      _schema: sync@1
      them:
        uuid: #{peer}
        sync:
          us:
            transfer: #{transfer}
      us:
        uuid: #{OC::WorkItems.instance_directory}
        sync:
          them:
            import: transferred
    YAML
  end

  describe '#freezes' do
    it 'names every issue in our own directory for a transfer of everything' do
      seed(sync_path('issues/1.yml'))
      seed(sync_path('issues/2.yml'))

      expect(reconciler(giving('all')).freezes(sha: sha)).to contain_exactly(
        have_attributes(kind: :freeze, peer: peer, path: sync_path('issues/1.yml'), source_iid: 1),
        have_attributes(kind: :freeze, peer: peer, path: sync_path('issues/2.yml'), source_iid: 2))
    end

    it 'names only what a list names' do
      seed(sync_path('issues/1.yml'))
      seed(sync_path('issues/2.yml'))

      decisions = reconciler(giving("\n            - issues/2.yml")).freezes(sha: sha)

      expect(decisions.map(&:source_iid)).to eq([2])
    end

    # Transfers are issues only for now, and `all` has to mean that too: a
    # project with both is an ordinary thing to write this about.
    it 'leaves merge requests out of a transfer of everything' do
      seed(sync_path('issues/1.yml'))
      seed(sync_path('merge_requests/3.yml'), "_schema: merge_requests@1\n")

      expect(reconciler(giving('all')).freezes(sha: sha).map(&:source_iid)).to eq([1])
    end

    it 'ignores catalogs and another instance directory' do
      seed(sync_path('issues/1.yml'))
      seed(sync_path('labels.yml'), "_schema: labels@1\n")
      seed("#{peer}/issues/9.yml")

      expect(reconciler(giving('all')).freezes(sha: sha).map(&:path))
        .to eq([sync_path('issues/1.yml')])
    end

    # An item that has never reached the branch cannot be handed over: freezing
    # it would stop it ever being written, and the other instance would wait
    # for a document nobody publishes. It is picked up on the run after the one
    # that writes it.
    it 'says nothing about an item the branch does not carry yet' do
      seed(sync_path('labels.yml'), "_schema: labels@1\n")

      expect(reconciler(giving('all')).freezes(sha: sha)).to be_empty
    end

    it 'says nothing when this instance is declared but gives nothing away' do
      seed(sync_path('issues/1.yml'))

      expect(reconciler(taking('all')).freezes(sha: sha)).to be_empty
    end

    it 'says nothing when the file does not declare this instance at all' do
      seed(sync_path('issues/1.yml'))

      expect(reconciler("---\n_schema: sync@1\n").freezes(sha: sha)).to be_empty
    end

    it 'says nothing without a branch' do
      expect(reconciler(giving('all')).freezes(sha: nil)).to be_empty
    end
  end

  describe '#promotions' do
    # A transfer is declared by the side losing the item, so a receiver never
    # finds one written under its own name.
    it 'reads what a peer promised us out of the peer own block' do
      seed("#{peer}/issues/7.yml")

      expect(reconciler(taking('all')).promotions(sha: sha)).to contain_exactly(
        have_attributes(kind: :promote, peer: peer, path: "#{peer}/issues/7.yml", source_iid: 7))
    end

    it 'attaches the row we hold for the document, when there is one' do
      seed("#{peer}/issues/7.yml")
      replica = create(:oc_replicated_work_item, project: project,
        source_instance_uuid: peer, source_iid: 7, source_path: "#{peer}/issues/7.yml")

      expect(reconciler(taking('all')).promotions(sha: sha).first.replica).to eq(replica)
    end

    # Not an error: the document may simply not have been imported yet, and a
    # declaration is standing intent rather than an instruction to act now.
    it 'attaches nothing when we hold no row for it' do
      seed("#{peer}/issues/7.yml")

      expect(reconciler(taking('all')).promotions(sha: sha).first.replica).to be_nil
    end

    it 'says nothing about our own directory' do
      seed(sync_path('issues/1.yml'))
      seed("#{peer}/issues/7.yml")

      expect(reconciler(taking('all')).promotions(sha: sha).map(&:path))
        .to eq(["#{peer}/issues/7.yml"])
    end

    it 'says nothing when the peer is only taking from us' do
      seed("#{peer}/issues/7.yml")

      expect(reconciler(giving('all')).promotions(sha: sha)).to be_empty
    end
  end
end
