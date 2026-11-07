# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../support/helpers/work_item_sync_paths'

# Offline issue edits end to end: sync an issue, edit its file, run the push
# check and the worker the push would start, then the sync, and read the
# branch back.
RSpec.describe 'offline issue edits end to end', feature_category: :source_code_management do
  include WorkItemSyncPaths

  let_it_be(:owner) { create(:user, :with_namespace) }
  let_it_be(:developer) { create(:user) }

  let(:project) { create(:project, :repository, :private, namespace: owner.namespace) }
  let(:repository) { project.repository }
  let(:branch) { OC::WorkItems::SYNC_BRANCH }
  let(:issue) { create(:issue, project: project, title: 'Login fails') }
  let(:path) { sync_path("issues/#{issue.iid}.yml") }

  before do
    project.add_developer(developer)
    project.enable_work_items_sync!(true)
    OC::WorkItems::SyncService.new(project).execute([issue])
  end

  def on_branch
    YAML.safe_load(repository.blob_at(repository.commit(branch).sha, path).data, permitted_classes: [Date, Time])
  end

  # Commits the edited file as the developer and runs what the push would:
  # the check before it lands, the worker and the sync after.
  def push_edit
    oldrev = repository.commit(branch).sha
    content = on_branch.tap { |doc| yield doc }
    repository.commit_files(developer, branch_name: branch, message: 'edit offline',
      actions: [{ action: :update, file_path: path, content: content.to_yaml }])
    newrev = repository.commit(branch).sha

    change_access = Gitlab::Checks::SingleChangeAccess.new(
      { oldrev: oldrev, newrev: newrev, ref: "refs/heads/#{branch}" },
      project: project, user_access: Gitlab::UserAccess.new(developer, container: project), protocol: 'ssh',
      logger: Gitlab::Checks::TimedLogger.new(timeout: Gitlab::GitAccess::INTERNAL_TIMEOUT))
    OC::Gitlab::Checks::ItemEditCheck.new(change_access).validate!

    OC::WorkItems::ItemEditsWorker.new.perform(project.id, developer.id, oldrev, newrev)
    OC::WorkItems::SyncWorker.drain
  end

  it 'applies the edit as the pusher and publishes the result, ready for the next edit' do
    push_edit do |doc|
      doc['title'] = 'Login fails after password reset'
      doc['state'] = 'closed'
      doc['notes'] = Array(doc['notes']) + [{ 'note' => 'Fixed by resetting the session.' }]
    end

    expect(issue.reload).to have_attributes(title: 'Login fails after password reset', state: 'closed')
    comment = issue.notes.user.sole
    expect(comment).to have_attributes(author: developer, note: 'Fixed by resetting the session.')

    published = on_branch
    expect(published['title']).to eq('Login fails after password reset')
    expect(published['notes'].find { |note| !note['system'] }).to include('author_id' => developer.id)

    push_edit { |doc| doc['notes'].find { |note| !note['system'] }['note'] = 'Fixed by clearing the cache.' }

    expect(comment.reload.note).to eq('Fixed by clearing the cache.')
  end

  it 'refuses an edit to a field that changed on the web, and puts the branch right' do
    issue.update_column(:title, 'Changed on the web')

    expect { push_edit { |doc| doc['title'] = 'Mine' } }
      .to raise_error(Gitlab::GitAccess::ForbiddenError, /"title" changed since your copy/)

    OC::WorkItems::SyncWorker.drain
    expect(on_branch['title']).to eq('Changed on the web')
  end
end
