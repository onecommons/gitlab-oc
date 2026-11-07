# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../support/helpers/work_item_sync_paths'

RSpec.describe OC::WorkItems::DraftService, feature_category: :source_code_management do
  include WorkItemSyncPaths

  let(:project) { create(:project, :repository, :private) }
  let(:developer) { create(:user) }
  let(:guest) { create(:user) }
  let(:branch) { OC::WorkItems::SYNC_BRANCH }

  before do
    project.add_developer(developer)
    project.add_guest(guest)
  end

  def inbox(name)
    sync_path("_incoming/#{name}")
  end

  def push_draft(name, title: 'T', **extra)
    content = { '_schema' => 'issue_draft@1', 'title' => title }.merge(extra.transform_keys(&:to_s)).to_yaml
    path = inbox(name)
    action = project.repository.blob_at(branch, path) ? :update_file : :create_file
    project.repository.public_send(action, developer, path, content, message: 'draft', branch_name: branch)
  end

  def run(user = developer)
    described_class.new(project, user).execute
  end

  it 'creates the issue as the pusher, with what the draft says, and records the key' do
    label = create(:label, project: project, title: 'bug')
    milestone = create(:milestone, project: project, title: '17.4')
    push_draft('fix-login.yml', title: 'Login fails', description: 'Details', labels: ['bug'],
      milestone: '17.4', assignees: [developer.username], due_date: '2026-12-01')

    result = run

    issue = result.created.sole
    expect(issue).to have_attributes(
      title: 'Login fails', description: 'Details', author: developer, labels: [label],
      milestone: milestone, assignees: [developer], due_date: Date.new(2026, 12, 1))
    expect(OC::WorkItems::Draft.find_by(project: project, key: 'fix-login'))
      .to have_attributes(issue: issue, iid: issue.iid)
  end

  it 'creates a missing label when the pusher may' do
    push_draft('a.yml', labels: ['brand-new'])

    expect(run.created.sole.labels.map(&:title)).to eq(['brand-new'])
  end

  it 'leaves a draft whose missing label the pusher may not create, and reports why' do
    push_draft('a.yml', labels: ['brand-new'])

    result = run(guest)

    expect(result.created).to be_empty
    expect(result.skipped['a']).to include('label "brand-new" does not exist, and you cannot create labels')
    expect(OC::WorkItems::Draft.count).to eq(0)
  end

  it 'leaves every draft when the pusher cannot create issues' do
    push_draft('a.yml')

    expect(run(create(:user)).skipped['a']).to eq('you cannot create issues in this project')
  end

  it 'leaves a draft naming an assignee who does not exist' do
    push_draft('a.yml', assignees: ['nobody-here'])

    expect(run.skipped['a']).to include('no user nobody-here can be assigned')
  end

  it 'leaves a draft with more assignees than this edition allows' do
    push_draft('a.yml', assignees: [developer.username, guest.username])

    expect(run.skipped['a']).to eq('only one assignee is allowed')
  end

  it 'leaves a confidential draft once the project is no longer private' do
    push_draft('a.yml', confidential: true)
    project.update!(visibility_level: Gitlab::VisibilityLevel::PUBLIC)

    expect(run.skipped['a']).to eq('confidential drafts are only created on private projects')
  end

  it 'creates the drafts it can when one fails' do
    push_draft('a-bad.yml', assignees: ['nobody-here'])
    push_draft('b-good.yml', title: 'Good')

    result = run

    expect(result.created.map(&:title)).to eq(['Good'])
    expect(result.skipped.keys).to eq(['a-bad'])
  end

  it 'leaves no issue behind when recording the draft fails, so a retry cannot duplicate it' do
    push_draft('a.yml')
    allow(OC::WorkItems::Draft).to receive(:create!).and_raise(ActiveRecord::RecordInvalid)

    result = run

    expect(project.issues.count).to eq(0)
    expect(result.skipped['a']).to start_with('it could not be created')
  end

  it 'creates the other drafts when one raises unexpectedly' do
    push_draft('a.yml', title: 'A')
    push_draft('b.yml', title: 'B')
    allow(Issues::CreateService).to receive(:new).and_call_original
    allow(Issues::CreateService).to receive(:new).with(hash_including(params: hash_including(title: 'A')))
      .and_raise(StandardError, 'boom')

    result = run

    expect(result.created.map(&:title)).to eq(['B'])
    expect(result.skipped['a']).to eq('it could not be created: boom')
  end

  it 'creates nothing the second time, and reports the draft as stale' do
    push_draft('a.yml')
    run

    result = run

    expect(result.created).to be_empty
    expect(result.stale).to eq([inbox('a.yml')])
    expect(project.issues.count).to eq(1)
  end

  it 'creates a task when the draft asks for one' do
    push_draft('a.yml', type: 'task')

    expect(run.created.sole.work_item_type.base_type).to eq('task')
  end

  it 'creates a missing milestone when the pusher may' do
    push_draft('a.yml', milestone: 'Next')

    expect(run.created.sole.milestone.title).to eq('Next')
  end

  it 'creates an incident when the draft asks for one' do
    project.add_maintainer(developer)
    push_draft('a.yml', type: 'incident')

    expect(run.created.sole.work_item_type.base_type).to eq('incident')
  end

  it 'matches assignees whatever their case' do
    push_draft('a.yml', assignees: [developer.username.upcase])

    expect(run.created.sole.assignees).to eq([developer])
  end

  it 'counts a batch in creations, so refused drafts cannot hold up the rest' do
    stub_const("#{described_class}::BATCH_SIZE", 1)
    push_draft('a-refused.yml', assignees: ['nobody-here'])
    push_draft('b-refused.yml', assignees: ['nobody-here'])
    push_draft('c-good.yml', title: 'Good')

    result = run

    expect(result.created.map(&:title)).to eq(['Good'])
    expect(result.more).to be(false)
  end

  it 'works through the inbox in batches' do
    stub_const("#{described_class}::BATCH_SIZE", 1)
    push_draft('a.yml')
    push_draft('b.yml')

    first = run

    expect(first.created.size).to eq(1)
    expect(first.more).to be(true)
    expect(run.more).to be(false)
    expect(project.issues.count).to eq(2)
  end

  it 'ignores files in the inbox that are not drafts, and other installations\' inboxes' do
    project.repository.create_file(developer, inbox('README.md'), 'notes', message: 'x', branch_name: branch)
    project.repository.create_file(developer, 'ffffffff-0000-0000-0000-000000000000/_incoming/x.yml',
      { '_schema' => 'issue_draft@1', 'title' => 'Theirs' }.to_yaml, message: 'x', branch_name: branch)

    expect(run.created).to be_empty
  end

  # A peer importing our directory reads only issue, merge request and commit
  # notes documents, so it never sees drafts.
  it 'is invisible to a peer importing our directory' do
    expect(OC::WorkItems::RecordSerializer.parse_path(inbox('a.yml'))).to be_nil
  end
end
