# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../support/helpers/work_item_sync_paths'

RSpec.describe OC::WorkItems::TransferService, feature_category: :source_code_management do
  include WorkItemSyncPaths

  let(:project) { create(:project) }
  let(:peer) { '11111111-2222-3333-4444-555555555555' }
  let(:service) { described_class.new(project) }
  let(:issue) { create(:issue, project: project) }

  def decision_for(record, iid: nil)
    iid ||= record&.iid

    OC::WorkItems::TransferReconciler::Decision.new(
      kind: :freeze, peer: peer, path: sync_path("issues/#{iid}.yml"),
      source_iid: iid, oid: 'a' * 40)
  end

  def row_for(record)
    record.reload.oc_replica
  end

  # Creating a project logs, and several examples below assert on what is
  # logged. Building it up front keeps its own noise out of them.
  before do
    service
  end

  describe '#freeze_for_transfer' do
    it 'records that the item is on its way, and to whom' do
      service.freeze_for_transfer(decision_for(issue))

      expect(row_for(issue)).to have_attributes(
        state: 'surrendered',
        source_instance_uuid: peer,
        source_path: sync_path("issues/#{issue.iid}.yml"),
        source_iid: issue.iid,
        source_blob_oid: 'a' * 40)
    end

    # The core of the design: the window between the two pushes can be days,
    # and an edit made here in the meantime would be silently superseded by
    # whatever the new owner publishes. Nothing about the other instance is
    # waited for.
    it 'makes the item read-only immediately, before anybody has taken it' do
      service.freeze_for_transfer(decision_for(issue))

      expect(Ability.allowed?(project.first_owner, :update_issue, issue.reload)).to be(false)
      expect(Ability.allowed?(project.first_owner, :read_issue, issue)).to be(true)
    end

    it 'is a no-op the second time, and says nothing about it' do
      service.freeze_for_transfer(decision_for(issue))
      first = row_for(issue)

      expect(::Gitlab::AppLogger).not_to receive(:info)

      service.freeze_for_transfer(decision_for(issue))

      expect(row_for(issue)).to eq(first)
      expect(OC::WorkItems::ReplicatedWorkItem.count).to eq(1)
    end

    # Between the decision and the insert, another run may have frozen it.
    it 'treats losing a race to another run as already done' do
      allow(OC::WorkItems::ReplicatedWorkItem).to receive(:create!)
        .and_raise(ActiveRecord::RecordNotUnique, 'beaten to it')

      expect { service.freeze_for_transfer(decision_for(issue)) }.not_to raise_error
    end

    describe 'refusals' do
      def expect_refusal(matching)
        expect(::Gitlab::AppLogger).to receive(:info)
          .with(hash_including(refusal_reason: a_string_matching(matching)))
      end

      it 'refuses an item that is not here' do
        expect_refusal(/no such issue/)

        service.freeze_for_transfer(decision_for(nil, iid: 999))

        expect(OC::WorkItems::ReplicatedWorkItem.count).to eq(0)
      end

      # Never published in the first place, so there is nothing for the other
      # instance to take. Both sides refuse them, so neither waits on the other.
      it 'refuses a confidential issue' do
        confidential = create(:issue, project: project, confidential: true)
        expect_refusal(/confidential/)

        service.freeze_for_transfer(decision_for(confidential))

        expect(row_for(confidential)).to be_nil
      end

      # `transfer: all` sweeps up the reference files in our directory by
      # construction, and a reference file's path looks exactly like a
      # document's. Only the row tells them apart.
      it 'refuses a copy of somebody else own item' do
        create(:oc_replicated_work_item, project: project, issue: issue,
          source_instance_uuid: '99999999-8888-7777-6666-555555555555')
        expect_refusal(/copy of it/)

        service.freeze_for_transfer(decision_for(issue.reload))

        expect(row_for(issue)).to be_state_imported
      end

      # The ratchet, and the case a path-keyed check would miss: an adopted row
      # is filed under the path the item came *from*, in the old owner's
      # directory, while the declaration that would claim it back names its new
      # path in ours. Looking the state up by path finds nothing at all.
      it 'refuses to give back an item that was transferred here' do
        create(:oc_replicated_work_item, :adopted, project: project, issue: issue,
          source_instance_uuid: peer, source_iid: 7,
          source_path: "#{peer}/issues/7.yml")
        expect_refusal(/not reversible/)

        service.freeze_for_transfer(decision_for(issue.reload))

        expect(row_for(issue)).to be_state_adopted
      end

      it 'refuses an item another instance also holds natively' do
        create(:oc_replicated_work_item, :matched, project: project, issue: issue,
          source_instance_uuid: peer)
        expect_refusal(/settled first/)

        service.freeze_for_transfer(decision_for(issue.reload))

        expect(row_for(issue)).to be_state_matched
      end
    end
  end

  describe '#promote' do
    let(:path) { "#{peer}/issues/7.yml" }
    let(:document) { { 'title' => 'Handed over' } }

    def promotion(replica)
      OC::WorkItems::TransferReconciler::Decision.new(
        kind: :promote, peer: peer, path: path, source_iid: 7,
        oid: replica&.source_blob_oid, replica: replica)
    end

    def imported_row(state = :imported)
      create(:oc_replicated_work_item, project: project, issue: issue, state: state,
        source_instance_uuid: peer, source_iid: 7, source_path: path)
    end

    it 'makes the copy ours, and stops the policy preventing writes' do
      replica = imported_row

      service.promote(promotion(replica), document)

      expect(replica.reload).to be_state_adopted
      expect(Ability.allowed?(project.first_owner, :update_issue, issue.reload)).to be(true)
    end

    it 'queues the item for publishing, which is what tells the old owner' do
      replica = imported_row

      expect(OC::WorkItems).to receive(:enqueue_sync).with(issue)

      service.promote(promotion(replica), document)
    end

    # Nothing will rebuild a promoted item again, so a list of references it
    # was still waiting for would sit there meaning nothing.
    it 'forgets what the copy was still waiting for' do
      replica = imported_row
      replica.update!(unresolved: [3, 4])

      service.promote(promotion(replica), document)

      expect(replica.reload.unresolved).to be_empty
    end

    # The matched path never went through the importer, so nothing turned sync
    # on -- and in the migration this is written for, the receiving instance
    # has it off. Without this the document is never published and the giver
    # waits frozen for ever.
    it 'turns sync on for an item that was already ours' do
      project.enable_work_items_sync!(false)
      project.custom_attributes.find_by(key: 'work_items_sync').destroy!
      replica = imported_row(:matched)

      service.promote(promotion(replica), document)

      expect(replica.reload).to be_state_adopted
      expect(project.reload.work_items_sync_enabled?).to be(true)
    end

    it 'does nothing the second time' do
      replica = imported_row(:adopted)

      expect(OC::WorkItems).not_to receive(:enqueue_sync)

      expect { service.promote(promotion(replica), document) }
        .not_to change { replica.reload.updated_at }
    end

    describe 'refusals' do
      def expect_refusal(matching)
        expect(::Gitlab::AppLogger).to receive(:info)
          .with(hash_including(refusal_reason: a_string_matching(matching)))
      end

      # Standing intent, not an instruction to act now: the document may
      # simply not have been imported yet.
      it 'waits for a document nobody has imported' do
        expect_refusal(/not been imported/)

        expect(service.promote(promotion(nil), document)).to be_nil
      end

      it 'waits for a merge request whose commits have not arrived' do
        replica = imported_row(:deferred)
        expect_refusal(/deferred/)

        service.promote(promotion(replica), document)

        expect(replica.reload).to be_state_deferred
      end

      # The promote-side half of the ratchet. Without it, two instances that
      # both declare `transfer: all` split every item in two: each demotes its
      # original into a copy of the other's document, and the same run's
      # promote takes it straight back.
      it 'refuses a document that reached that instance from a third one' do
        replica = imported_row
        expect_refusal(/third one/)

        service.promote(promotion(replica), document.merge('transferred_from' => 'x/issues/1.yml'))

        expect(replica.reload).to be_state_imported
      end
    end

    # A concurrent run planned a rebuild or a delete against the state this row
    # is leaving. Both begin by destroying the record, and by then it is an
    # item somebody here owns and may have edited.
    describe 'racing a run that is still acting on the old state' do
      it 'refuses to promote a row that changed under it' do
        replica = imported_row
        stale = promotion(replica)
        OC::WorkItems::ReplicatedWorkItem.find(replica.id).update!(source_blob_oid: 'f' * 40)

        service.promote(stale, document)

        expect(replica.reload).to be_state_imported
      end
    end
  end
end
