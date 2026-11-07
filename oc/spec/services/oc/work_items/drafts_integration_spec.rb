# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../support/helpers/work_item_sync_paths'

# Offline issue drafts end to end: push two drafts that name each other, run
# the worker and the sync the push would start, and read the branch back.
RSpec.describe 'work item drafts end to end', feature_category: :source_code_management do
  include WorkItemSyncPaths

  let_it_be(:owner) { create(:user, :with_namespace) }
  let(:drafts) do
    {
      'session-cache.yml' => <<~YAML,
        _schema: issue_draft@1
        title: Session cache never invalidates
        description: 'Likely the cause of #draft:fix-login. See also #42.'
        labels: [bug]
      YAML
      'fix-login.yml' => <<~YAML
        _schema: issue_draft@1
        title: Login fails after password reset
        description: 'Blocked by #draft:session-cache.'
        assignees: [#{developer.username}]
      YAML
    }
  end

  let_it_be(:developer) { create(:user) }

  let(:project) { create(:project, :repository, :private, namespace: owner.namespace) }
  let(:repository) { project.repository }
  let(:branch) { OC::WorkItems::SYNC_BRANCH }

  before do
    project.add_developer(developer)
    project.enable_work_items_sync!(true)
    create(:label, project: project, title: 'bug')

    # The branch exists, as it would on a project already syncing.
    repository.create_file(owner, sync_path('ids.yml'), "---\n", message: 'seed', branch_name: branch)
  end

  def push_drafts(files)
    actions = files.map do |name, content|
      { action: :create, file_path: sync_path("_incoming/#{name}"), content: content }
    end
    repository.commit_files(developer, branch_name: branch, message: 'drafts', actions: actions)
  end

  def run_push
    OC::WorkItems::DraftsWorker.new.perform(project.id, developer.id)
    OC::WorkItems::SyncWorker.drain
  end

  def on_branch(path)
    repository.blob_at(repository.commit(branch).sha, sync_path(path))
  end

  def issue_for(key)
    OC::WorkItems::Draft.find_by(project: project, key: key).issue
  end

  it 'creates both issues as the pusher, links them, publishes them, and removes the drafts' do
    push_drafts(drafts)

    run_push

    login = issue_for('fix-login')
    cache = issue_for('session-cache')
    expect([login.author, cache.author]).to eq([developer, developer])
    expect(login.assignees).to eq([developer])
    expect(cache.labels.map(&:title)).to eq(['bug'])
    expect(login.description).to eq("Blocked by ##{cache.iid}.")
    expect(cache.description).to eq("Likely the cause of ##{login.iid}. See also #42.")

    expect(on_branch('_incoming/fix-login.yml')).to be_nil
    expect(on_branch('_incoming/session-cache.yml')).to be_nil
    expect(YAML.safe_load(on_branch("issues/#{login.iid}.yml").data)['description'])
      .to eq("Blocked by ##{cache.iid}.")
    expect(YAML.safe_load(on_branch('drafts.yml').data)['drafts'])
      .to eq('fix-login' => login.iid, 'session-cache' => cache.iid)
  end

  it 'creates nothing when an old copy of the drafts is pushed again' do
    push_drafts(drafts)
    run_push

    expect do
      push_drafts(drafts)
      run_push
    end.not_to change { project.issues.count }

    expect(on_branch('_incoming/fix-login.yml')).to be_nil
  end
end
