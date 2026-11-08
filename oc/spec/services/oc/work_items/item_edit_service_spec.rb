# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../support/helpers/work_item_sync_paths'

RSpec.describe OC::WorkItems::ItemEditService, feature_category: :source_code_management do
  let(:user) { create(:user) }
  let(:project) { create(:project, :repository, :private) }
  let(:issue) { create(:issue, project: project, title: 'Old') }
  let(:branch) { OC::WorkItems::SYNC_BRANCH }
  let(:uuid) { '11111111-2222-3333-4444-555555555555' }
  let(:path) { WorkItemSyncPaths.item_file(project.repository, uuid, issue.iid) }

  before do
    project.add_maintainer(user)
    allow(Gitlab::CurrentSettings).to receive(:uuid).and_return(uuid)
    project.enable_work_items_sync!(true)
  end

  def sync
    OC::WorkItems::SyncService.new(project).execute([issue.reload])
    project.repository.commit(branch).sha
  end

  def file
    YAML.safe_load(project.repository.blob_at(branch, path).data, permitted_classes: [Date, Time])
  end

  # The edit as a push: the branch before it and after it.
  def push_edit
    oldrev = sync
    content = file.tap { |doc| yield doc }
    project.repository.commit_files(user, branch_name: branch, message: 'edit offline',
      actions: [{ action: :update, file_path: path, content: content.to_yaml }])

    [oldrev, project.repository.commit(branch).sha]
  end

  def apply(revisions)
    described_class.new(project, user).execute(*revisions)
  end

  it 'applies field edits as the pusher' do
    milestone = create(:milestone, project: project, title: '1.0')
    create(:label, project: project, title: 'bug')

    result = apply(push_edit do |doc|
      doc.merge!('title' => 'New', 'description' => 'Offline', 'due_date' => '2026-12-01',
        'label_links' => [{ 'label' => { 'title' => 'bug' } }], 'milestone' => { 'title' => '1.0' })
    end)

    expect(result.applied).to eq([issue.iid])
    expect(issue.reload).to have_attributes(title: 'New', description: 'Offline',
      due_date: Date.new(2026, 12, 1), milestone: milestone)
    expect(issue.labels.map(&:title)).to eq(%w[bug])
    expect(issue.notes.system.last.author).to eq(user)
  end

  it 'adds and removes labels on their own, keeping one added on the web since' do
    issue.update!(labels: [create(:label, project: project, title: 'bug')])
    create(:label, project: project, title: 'ux')
    revisions = push_edit { |doc| doc['label_links'] = [{ 'label' => { 'title' => 'ux' } }] }
    issue.labels << create(:label, project: project, title: 'security')

    expect(apply(revisions).applied).to eq([issue.iid])
    expect(issue.reload.labels.map(&:title)).to contain_exactly('security', 'ux')
  end

  it 'removes labels and the milestone' do
    issue.update!(labels: [create(:label, project: project, title: 'bug')],
      milestone: create(:milestone, project: project))

    apply(push_edit { |doc| doc.except!('label_links', 'milestone') })

    expect(issue.reload.labels).to be_empty
    expect(issue.milestone).to be_nil
  end

  it 'closes and reopens' do
    apply(push_edit { |doc| doc['state'] = 'closed' })
    expect(issue.reload).to be_closed

    apply(push_edit { |doc| doc['state'] = 'opened' })
    expect(issue.reload).to be_opened
  end

  it 'adds comments and edits your own' do
    mine = create(:note, noteable: issue, project: project, author: user, note: 'Before')

    apply(push_edit do |doc|
      doc['notes'].first['note'] = 'After'
      doc['notes'] << { 'note' => 'Added offline' }
    end)

    expect(mine.reload.note).to eq('After')
    expect(issue.notes.user.where(note: 'Added offline').sole.author).to eq(user)
  end

  it 'skips only an edit it cannot apply, and says why' do
    revisions = push_edit { |doc| doc['title'] = 'New' }
    project.add_guest(user)

    result = apply(revisions)

    expect(result.skipped).to eq(issue.iid => 'you cannot edit this issue')
    expect(issue.reload.title).to eq('Old')
  end

  describe 'when the issue moved on after the push' do
    it 'skips the whole issue if a field it changes was changed on the web, and syncs it' do
      revisions = push_edit { |doc| doc.merge!('title' => 'Mine', 'description' => 'Mine too') }
      issue.update_column(:title, 'Changed on the web')

      expect(OC::WorkItems).to receive(:enqueue_sync).with(issue, user)

      result = apply(revisions)

      expect(result.skipped).to eq(issue.iid => '"title" changed after the push')
      expect(issue.reload.description).not_to eq('Mine too')
    end

    it 'applies it anyway when only other fields changed' do
      revisions = push_edit { |doc| doc['title'] = 'Mine' }
      issue.update_column(:description, 'Changed on the web')

      expect(apply(revisions).applied).to eq([issue.iid])
      expect(issue.reload.title).to eq('Mine')
    end
  end

  it 'syncs an issue it could not apply' do
    revisions = push_edit { |doc| doc['title'] = 'New' }
    allow(Issues::UpdateService).to receive(:new).and_raise('boom')

    expect(OC::WorkItems).to receive(:enqueue_sync).with(issue, user)

    expect(apply(revisions).skipped).to eq(issue.iid => 'it could not be applied: boom')
  end

  it 'skips a file whose revision is gone by the time the job runs' do
    oldrev, newrev = push_edit { |doc| doc['title'] = 'New' }
    allow(project.repository).to receive(:blob_at).and_call_original
    allow(project.repository).to receive(:blob_at).with(newrev, path).and_return(nil)

    expect(apply([oldrev, newrev]).skipped[issue.iid]).to include('is no longer in the repository')
  end

  it 'does not post a new comment twice when retried' do
    revisions = push_edit { |doc| doc['notes'] = Array(doc['notes']) + [{ 'note' => 'Once' }] }

    2.times { apply(revisions) }

    expect(issue.notes.user.where(note: 'Once').count).to eq(1)
  end

  it 'does nothing again for a change the issue already has' do
    revisions = push_edit { |doc| doc['title'] = 'New' }
    apply(revisions)

    expect(Issues::UpdateService).not_to receive(:new)
    expect(apply(revisions).applied).to eq([issue.iid])
  end
end
