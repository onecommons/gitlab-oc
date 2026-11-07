# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OC::WorkItems::Draft, feature_category: :source_code_management do
  let_it_be(:project) { create(:project) }

  it 'is unique per project and key' do
    create(:oc_work_item_draft, project: project, key: 'fix-login')

    duplicate = build(:oc_work_item_draft, project: project, key: 'fix-login')

    expect(duplicate).not_to be_valid
    expect(build(:oc_work_item_draft, key: 'fix-login')).to be_valid
  end

  it 'refuses a key a draft filename could not have' do
    expect(build(:oc_work_item_draft, project: project, key: 'Fix Login')).not_to be_valid
  end

  it 'keeps the row, and its iid, when the issue is deleted' do
    draft = create(:oc_work_item_draft, project: project, key: 'gone')
    iid = draft.iid

    draft.issue.destroy!

    expect(draft.reload).to have_attributes(issue_id: nil, iid: iid)
  end

  it 'goes with its project' do
    other = create(:project)
    create(:oc_work_item_draft, project: other)

    expect { other.destroy! }.to change { described_class.count }.by(-1)
  end
end
