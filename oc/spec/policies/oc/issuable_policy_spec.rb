# frozen_string_literal: true

require 'spec_helper'

# The replica rows here are created directly rather than by importing anything.
# The policy only cares that a row exists, which is what makes it testable
# before the importer exists.
#
# Every example checks both directions -- allowed without the row, prevented
# with it. Asserting only the prevention would pass just as happily for an
# ability the user never had.
RSpec.describe 'OC::IssuablePolicy', feature_category: :source_code_management do
  # An Owner is deliberately the subject under test: a replica has to be
  # read-only for the person with the most rights on the project, or it is not
  # read-only at all.
  let_it_be(:owner) { create(:user, :with_namespace) }
  let_it_be(:project) { create(:project, :public, :repository, namespace: owner.namespace) }

  def allowed(abilities, issuable)
    abilities.select { |ability| Ability.allowed?(owner, ability, issuable) }
  end

  describe 'an issue' do
    let_it_be_with_reload(:issue) { create(:issue, project: project) }

    let(:write_abilities) do
      %i[
        update_issue admin_issue reopen_issue destroy_issue
        set_issue_metadata set_confidentiality admin_issue_relation admin_issue_link create_timelog
        create_note admin_note award_emoji
      ]
    end

    it 'is fully writable until it is a replica' do
      expect(allowed(write_abilities, issue)).to match_array(write_abilities)
    end

    context 'when it is a replica' do
      before do
        create(:oc_replicated_work_item, project: project, issue: issue)
        issue.reload
      end

      it 'prevents every write' do
        expect(allowed(write_abilities, issue)).to be_empty
      end

      it 'stays readable, which is the whole point of keeping it' do
        expect(Ability.allowed?(owner, :read_issue, issue)).to be(true)
      end

      # The same row seen through WorkItemPolicy. Some of these derive from the
      # issue ability of the same name; admin_work_item and the link abilities
      # are granted by the roles directly, so the derivation alone would leak.
      it 'prevents every write as a work item too' do
        work_item = WorkItem.find(issue.id)
        abilities = %i[
          update_work_item admin_work_item delete_work_item set_work_item_metadata
          admin_work_item_link admin_parent_link move_work_item clone_work_item create_note
        ]

        expect(abilities.select { |ability| Ability.allowed?(owner, ability, work_item) }).to be_empty
        expect(Ability.allowed?(owner, :read_work_item, work_item)).to be(true)
      end
    end

    # A row does not mean "somebody else's". Three of its states say the item is
    # ours, and two of those attach to a record that was never a copy of
    # anything -- an issue filed here, that a peer's document turned out to
    # describe. Making one of those read-only would be this feature's worst
    # possible failure: an item nobody imported quietly becoming uneditable.
    context 'when the row says the item is ours' do
      it 'leaves an adopted issue fully writable' do
        create(:oc_replicated_work_item, :adopted, project: project, issue: issue)

        expect(allowed(write_abilities, issue.reload)).to match_array(write_abilities)
      end

      it 'leaves a matched issue fully writable' do
        create(:oc_replicated_work_item, :matched, project: project, issue: issue)

        expect(allowed(write_abilities, issue.reload)).to match_array(write_abilities)
      end
    end

    # Frozen the moment the row exists, whether or not the other instance has
    # taken it yet. The push order is not something anyone can rely on, and the
    # window between the two pushes can be days.
    context 'when it is being transferred away' do
      it 'prevents every write' do
        create(:oc_replicated_work_item, :surrendered, project: project, issue: issue)

        expect(allowed(write_abilities, issue.reload)).to be_empty
      end
    end
  end

  describe 'a merge request' do
    let_it_be_with_reload(:merge_request) do
      create(:merge_request, source_project: project, target_project: project)
    end

    let(:write_abilities) do
      %i[
        update_merge_request admin_merge_request reopen_merge_request destroy_merge_request
        set_merge_request_metadata approve_merge_request
        create_note admin_note award_emoji
      ]
    end

    it 'is fully writable until it is a replica' do
      expect(allowed(write_abilities, merge_request)).to match_array(write_abilities)
    end

    context 'when it is a replica' do
      before do
        create(:oc_replicated_work_item, :merge_request_kind,
          project: project, merge_request: merge_request)
        merge_request.reload
      end

      it 'prevents every write' do
        expect(allowed(write_abilities, merge_request)).to be_empty
      end

      it 'stays readable' do
        expect(Ability.allowed?(owner, :read_merge_request, merge_request)).to be(true)
      end
    end
  end

  # A deferred row has no local record at all. The partial index allows many of
  # them, so they must not make some unrelated issue read-only by association.
  describe 'a row with no local record' do
    it 'leaves ordinary issues alone' do
      issue = create(:issue, project: project)
      create(:oc_replicated_work_item, :deferred, :merge_request_kind, project: project)

      expect(Ability.allowed?(owner, :update_issue, issue.reload)).to be(true)
    end
  end
end
