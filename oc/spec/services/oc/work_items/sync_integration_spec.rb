# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../support/helpers/work_item_sync_paths'

RSpec.describe 'work items sync end to end', feature_category: :source_code_management do
  include WorkItemSyncPaths

  let_it_be(:user) { create(:user, :with_namespace) }

  let(:project) { create(:project, :repository, namespace: user.namespace) }
  let(:repository) { project.repository }
  let(:branch) { OC::WorkItems::SYNC_BRANCH }

  before do
    project.enable_work_items_sync!(true)
  end

  def drain_sync_workers
    OC::WorkItems::SyncWorker.drain
    OC::WorkItems::FullSyncWorker.drain
  end

  it 'commits each change exactly once and converges on re-fired hooks' do
    issue = Issues::CreateService
      .new(container: project, current_user: user, params: { title: 'first' }, perform_spam_check: false)
      .execute.payload[:issue]

    drain_sync_workers

    expect(repository.branch_exists?(branch)).to be(true)
    first_sha = repository.commit(branch).sha
    first_yaml = YAML.safe_load(repository.blob_at(first_sha, sync_path("issues/#{issue.iid}.yml")).data)
    expect(first_yaml['title']).to eq('first')
    # Not an equality check: the trailers vary by how the commit was made (a
    # full pass adds a watermark, an incremental one does not).
    expect(repository.commit(branch).message).to start_with(OC::WorkItems::COMMIT_MESSAGE)

    # A re-fired hook for an unchanged issue (e.g. via MR refresh after our
    # own sync push) must not produce another commit -- this terminates the loop.
    OC::WorkItems::SyncWorker.new.perform(project.id, 'Issue', issue.id, issue.iid, user.id)
    expect(repository.commit(branch).sha).to eq(first_sha)

    Issues::UpdateService
      .new(container: project, current_user: user, params: { title: 'second' })
      .execute(issue)

    drain_sync_workers

    second_sha = repository.commit(branch).sha
    expect(second_sha).not_to eq(first_sha)
    second_yaml = YAML.safe_load(repository.blob_at(second_sha, sync_path("issues/#{issue.iid}.yml")).data)
    expect(second_yaml['title']).to eq('second')
  end

  # The worker looks its issuable up by id, so a job outlived by the record it
  # names lands on the removal path. That is right for a deletion and wrong for
  # a rebuild, where the record was destroyed and recreated under the same iid
  # -- and the worker cannot tell those apart from the id alone.
  #
  # Driven through the worker rather than the service because the worker is
  # what decides to call remove at all; a service-level test would not prove
  # the two halves meet.
  it 'keeps the file when the record behind a queued job was replaced, not deleted' do
    issue = create(:issue, project: project, title: 'original')
    # A full pass rather than SyncWorker: with no branch yet the incremental
    # worker defers to one anyway, and building it here keeps the example about
    # the removal path.
    OC::WorkItems::FullSyncWorker.new.perform(project.id)

    path = sync_path("issues/#{issue.iid}.yml")
    expect(repository.blob_at(repository.commit(branch).sha, path)).to be_present

    # Exactly the state a rebuild leaves the queued job in: the id it carries
    # no longer resolves, while a live record holds that iid.
    OC::WorkItems::SyncWorker.new.perform(
      project.id, 'Issue', non_existing_record_id, issue.iid, user.id)

    expect(repository.blob_at(repository.commit(branch).sha, path)).to be_present
  end
end
