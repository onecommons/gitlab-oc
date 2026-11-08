# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../../support/helpers/work_item_sync_paths'

RSpec.describe OC::Gitlab::Checks::ItemEditCheck, feature_category: :source_code_management do
  let(:user) { create(:user) }
  let(:project) { create(:project, :repository, :private) }
  let(:issue) { create(:issue, project: project, title: 'Old') }
  let(:user_access) { Gitlab::UserAccess.new(user, container: project) }
  let(:branch) { OC::WorkItems::SYNC_BRANCH }
  let(:uuid) { '11111111-2222-3333-4444-555555555555' }
  let(:path) { WorkItemSyncPaths.item_file(project.repository, uuid, issue.iid) }
  let(:logger) { Gitlab::Checks::TimedLogger.new(timeout: Gitlab::GitAccess::INTERNAL_TIMEOUT) }

  before do
    project.add_maintainer(user)
    allow(Gitlab::CurrentSettings).to receive(:uuid).and_return(uuid)
    project.enable_work_items_sync!(true)
  end

  def check(oldrev:, newrev:)
    change_access = Gitlab::Checks::SingleChangeAccess.new(
      { oldrev: oldrev, newrev: newrev, ref: "refs/heads/#{branch}" },
      project: project, user_access: user_access, protocol: 'ssh', logger: logger)

    described_class.new(change_access)
  end

  def sync(*issues)
    OC::WorkItems::SyncService.new(project).execute(issues.map(&:reload))
    project.repository.commit(branch).sha
  end

  def file(at = path)
    YAML.safe_load(project.repository.blob_at(branch, at).data, permitted_classes: [Date, Time])
  end

  def push(changes, message: 'edit offline')
    actions = changes.map do |file_path, content|
      next { action: :delete, file_path: file_path } if content.nil?

      action = project.repository.blob_at(branch, file_path) ? :update : :create
      { action: action, file_path: file_path, content: content.is_a?(Hash) ? content.to_yaml : content }
    end

    project.repository.commit_files(user, branch_name: branch, message: message, actions: actions)
    project.repository.commit(branch).sha
  end

  def refusal(oldrev, newrev)
    check(oldrev: oldrev, newrev: newrev).validate!
    nil
  rescue Gitlab::GitAccess::ForbiddenError => error
    error.message
  end

  def edit(&block)
    old = sync(issue)
    new = push({ path => file.tap(&block) })

    refusal(old, new)
  end

  it 'accepts a title edit and a new comment' do
    expect(edit { |doc| doc.merge!('title' => 'New', 'notes' => [{ 'note' => 'Offline' }]) }).to be_nil
  end

  it 'refuses a change it cannot apply, naming the file' do
    expect(edit { |doc| doc['author_id'] = 0 })
      .to eq("Work items sync: #{path}: \"author_id\" cannot be changed offline")
  end

  # git reports a rename as a delete and an add; under one number they are
  # one edit, checked like any other.
  it 'checks an edit made in a renamed file, naming the new path' do
    old = sync(issue)
    renamed = "#{uuid}/issues/#{issue.iid}-mine.yml"
    project.repository.commit_files(user, branch_name: branch, message: 'rename', actions: [
      { action: :move, previous_path: path, file_path: renamed, content: file.merge('author_id' => 0).to_yaml }
    ])

    expect(refusal(old, project.repository.commit(branch).sha))
      .to eq("Work items sync: #{renamed}: \"author_id\" cannot be changed offline")
  end

  it 'refuses edits while sync is off' do
    old = sync(issue)
    project.enable_work_items_sync!(false)
    new = push({ path => file.merge('title' => 'New') })

    expect(refusal(old, new)).to include('while work items sync is off')
  end

  it 'ignores files it does not apply: other generated files, added and deleted issue files' do
    other = create(:issue, project: project)
    old = sync(issue, other)
    new = push({
      "#{uuid}/ids.yml" => "edited: true\n",
      "#{uuid}/issues/9999.yml" => "title: added\n",
      WorkItemSyncPaths.item_file(project.repository, uuid, other.iid) => nil
    })

    expect(refusal(old, new)).to be_nil
  end

  it 'does not stand in the way of our own sync commits' do
    old = sync(issue)
    issue.update!(title: 'Changed on the web')
    new = sync(issue)

    expect(project.repository.commit(new).message).to start_with(OC::WorkItems::COMMIT_MESSAGE)
    expect(refusal(old, new)).to be_nil
  end

  it 'does not stand in the way of a full sync pass' do
    old = sync(issue)
    issue.update!(title: 'Changed on the web')
    OC::WorkItems::FullSyncWorker.new.perform(project.id)

    expect(refusal(old, project.repository.commit(branch).sha)).to be_nil
  end

  # A force push of an older copy would read every field it takes back as
  # an edit, and write the old values into the issue.
  it 'refuses a force push that changes issue files' do
    old_copy = sync(issue)
    issue.update!(title: 'Changed on the web')
    current = sync(issue)
    project.repository.commit_files(user, branch_name: 'older', start_sha: old_copy, message: 'older',
      actions: [{ action: :update, file_path: "#{uuid}/ids.yml", content: "---\n" }])
    older = project.repository.commit('older').sha

    expect(refusal(current, older)).to include('a force push cannot edit issues')
  end

  describe 'conflicts' do
    it 'refuses an edit to a field that changed since the copy, and syncs the item' do
      old = sync(issue)
      issue.update_column(:title, 'Changed on the web')
      new = push({ path => file.merge('title' => 'Mine') })

      expect(OC::WorkItems::SyncWorker).to receive(:perform_in)
      expect(refusal(old, new))
        .to eq("Work items sync: #{path}: issue ##{issue.iid}: \"title\" changed since your copy; " \
          'pull and push again')
    end

    it 'does not count a change to another field, or a new comment on the web' do
      old = sync(issue)
      issue.update_column(:description, 'Changed on the web')
      create(:note, noteable: issue, project: project, note: 'From the web')
      new = push({ path => file.merge('title' => 'Mine') })

      expect(refusal(old, new)).to be_nil
    end

    it 'accepts an edit the issue already has' do
      old = sync(issue)
      issue.update_column(:title, 'Same')
      new = push({ path => file.merge('title' => 'Same') })

      expect(refusal(old, new)).to be_nil
    end
  end

  describe 'comments' do
    let(:other_user) { create(:user, developer_of: project) }

    def edit_comment(author)
      create(:note, noteable: issue, project: project, author: author, note: 'Before')
      edit { |doc| doc['notes'].first['note'] = 'After' }
    end

    it 'accepts an edit to your own comment' do
      expect(edit_comment(user)).to be_nil
    end

    it "refuses an edit to someone else's comment" do
      expect(edit_comment(other_user)).to include('you can only change your own comments')
    end
  end

  it 'refuses a confidentiality change the pusher may not make' do
    allow(Ability).to receive(:allowed?).and_call_original
    allow(Ability).to receive(:allowed?).with(user, :set_confidentiality, anything).and_return(false)

    expect(edit { |doc| doc['confidential'] = true }).to include('whether this issue is confidential')
  end

  it 'refuses a change the pusher may not make' do
    project.add_guest(user)

    expect(edit { |doc| doc['title'] = 'New' }).to include('cannot be edited by you: you cannot edit this issue')
  end

  it 'refuses an edit to an issue that no longer exists' do
    old = sync(issue)
    new = push({ path => file.merge('title' => 'New') })
    OC::WorkItems.suppress_sync { issue.destroy! }

    expect(refusal(old, new)).to include("issue ##{issue.iid} does not exist here")
  end

  it 'refuses a push editing too many issues' do
    stub_const("#{described_class}::MAX_ITEMS", 1)
    other = create(:issue, project: project)
    old = sync(issue, other)
    other_path = WorkItemSyncPaths.item_file(project.repository, uuid, other.iid)
    new = push({ path => file.merge('title' => 'A'), other_path => file(other_path).merge('title' => 'B') })

    expect(refusal(old, new)).to include('this push edits 2 issues; at most 1')
  end
end
