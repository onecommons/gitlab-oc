# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OC::WorkItems::ReconcileWorker, feature_category: :source_code_management do
  let(:worker) { described_class.new }

  def make_opted_in(project)
    project.custom_attributes.create!(key: 'unfurl_type', value: OC::REGULAR_PROJECT)
    project.custom_attributes.create!(key: 'work_items_sync', value: 'enabled')
  end

  def make_unfurl(project)
    project.custom_attributes.create!(key: 'unfurl_type', value: OC::UNFURL_DASHBOARD)
  end

  # watermark: what the last sync commit claims it scanned through, i.e.
  # `Work-Items-Synced-Through`. nil means the commit carries no watermark, so
  # the reconcile has no safe window and must ask for an unfiltered pass.
  def stub_sync_commit(committed_date, watermark: nil)
    message = OC::WorkItems.commit_message(synced_through: watermark)
    # Commit delegates committed_date to the raw commit, so a verifying
    # double can't be used here.
    commit = committed_date && double('commit', committed_date: committed_date, message: message) # rubocop:disable RSpec/VerifiedDoubles -- committed_date is delegated to the raw commit

    allow_next_found_instances_of(Project, 5) do |found|
      allow(found).to receive(:repository)
        .and_return(instance_double(Repository, commit: commit))
    end
  end

  def expect_full_sync(project, since: nil)
    expect(OC::WorkItems::FullSyncWorker).to receive(:perform_in)
      .with(anything, project.id, false, since)
  end

  describe '#perform' do
    it 'enqueues full syncs for unfurl and opted-in projects with unsynced content' do
      unfurl = create(:project).tap { |p| make_unfurl(p) }
      opted_in = create(:project).tap { |p| make_opted_in(p) }
      create(:project).tap { |p| p.custom_attributes.create!(key: 'unfurl_type', value: OC::REGULAR_PROJECT) }
      create(:issue, project: unfurl)
      create(:issue, project: opted_in)

      stub_sync_commit(nil) # branch never created

      expect_full_sync(unfurl)
      expect_full_sync(opted_in)

      worker.perform
    end

    it 'enqueues a project only once even when multiple attributes match' do
      project = create(:project)
      make_unfurl(project)
      project.custom_attributes.create!(key: 'work_items_sync', value: 'enabled')
      create(:issue, project: project)

      stub_sync_commit(nil)

      expect(OC::WorkItems::FullSyncWorker).to receive(:perform_in).with(anything, project.id, false, nil).once

      worker.perform
    end

    it 'skips projects with nothing newer than the last pass' do
      project = create(:project).tap { |p| make_opted_in(p) }
      project.update_column(:updated_at, 2.days.ago)
      create(:issue, project: project, updated_at: 2.days.ago)
      project.record_work_items_sync!(1.day.ago, unfiltered: true)

      stub_sync_commit(1.day.ago)

      expect(OC::WorkItems::FullSyncWorker).not_to receive(:perform_in)

      worker.perform
    end

    # The point of comparing against the recorded pass rather than the sync
    # commit: on an instance where most projects are dormant, reading each
    # branch to discover nothing had changed was the bulk of this job.
    it 'never reads the repository of a project it skips' do
      project = create(:project).tap { |p| make_opted_in(p) }
      project.update_column(:updated_at, 2.days.ago)
      create(:issue, project: project, updated_at: 2.days.ago)
      project.record_work_items_sync!(1.day.ago, unfiltered: true)

      allow_next_found_instance_of(Project) do |found|
        expect(found).not_to receive(:repository)
      end

      worker.perform
    end

    it 'enqueues a project that has never been synced' do
      project = create(:project).tap { |p| make_opted_in(p) }
      create(:issue, project: project)

      stub_sync_commit(nil)

      expect_full_sync(project)

      worker.perform
    end

    it 'reconciles when the project itself changed (visibility, rename) after the last sync' do
      project = create(:project).tap { |p| make_opted_in(p) }
      project.update_column(:updated_at, 1.hour.ago)
      create(:issue, project: project, updated_at: 2.days.ago)

      stub_sync_commit(1.day.ago)

      expect_full_sync(project)

      worker.perform
    end

    it 'reconciles when an issue changed after the last sync commit' do
      project = create(:project).tap { |p| make_opted_in(p) }
      project.update_column(:updated_at, 2.days.ago)
      create(:issue, project: project, updated_at: 1.hour.ago)

      stub_sync_commit(1.day.ago)

      expect_full_sync(project)

      worker.perform
    end

    it 'reconciles when a label was renamed after the last sync commit' do
      project = create(:project).tap { |p| make_opted_in(p) }
      project.update_column(:updated_at, 2.days.ago)
      create(:issue, project: project, updated_at: 2.days.ago)
      create(:label, project: project, updated_at: 1.hour.ago)

      stub_sync_commit(1.day.ago)

      expect_full_sync(project)

      worker.perform
    end

    it 'reconciles when a group label of an ancestor group changed' do
      group = create(:group)
      project = create(:project, group: group).tap { |p| make_opted_in(p) }
      project.update_column(:updated_at, 2.days.ago)
      create(:issue, project: project, updated_at: 2.days.ago)
      create(:group_label, group: group, updated_at: 1.hour.ago)

      stub_sync_commit(1.day.ago)

      expect_full_sync(project)

      worker.perform
    end

    # A commit note touches no issuable, so nothing else in content_change_at
    # moves when one is written -- and a project whose only synced content is
    # commit notes has no issues or merge requests to fall back on.
    it 'reconciles a project whose only content is commit notes' do
      project = create(:project).tap { |p| make_opted_in(p) }
      project.update_column(:updated_at, 2.days.ago)
      create(:note_on_commit, project: project, updated_at: 1.hour.ago)

      stub_sync_commit(1.day.ago)

      expect_full_sync(project)

      worker.perform
    end

    it 'skips projects with nothing syncable at all' do
      create(:project).tap { |p| make_opted_in(p) }

      expect(OC::WorkItems::FullSyncWorker).not_to receive(:perform_in)

      worker.perform
    end
  end

  # The window keeps the nightly run proportional to the day's activity rather
  # than to the size of the project -- but only when issues and merge requests
  # are the only things that moved.
  describe 'the window it asks for' do
    let(:watermark) { 12.hours.ago.change(usec: 0) }

    def project_with_stale_issue
      create(:project).tap do |project|
        make_opted_in(project)
        project.update_column(:updated_at, 2.days.ago)
        create(:issue, project: project, updated_at: 1.hour.ago)
      end
    end

    it 'scopes to the last watermark when only issues changed' do
      project = project_with_stale_issue

      stub_sync_commit(1.day.ago, watermark: watermark)

      expect_full_sync(project, since: watermark.utc.iso8601)

      worker.perform
    end

    # A label's copy is embedded in every file that references it, and renaming
    # it touches none of them -- so a scoped pass would leave every one stale.
    it 'asks for an unfiltered pass when a label moved after the watermark' do
      project = project_with_stale_issue
      create(:label, project: project, updated_at: 1.hour.ago)

      stub_sync_commit(1.day.ago, watermark: watermark)

      expect_full_sync(project, since: nil)

      worker.perform
    end

    # A rename changes every embedded web_url; a visibility change rewrites the
    # confidential filtering. Neither touches a single issue.
    it 'asks for an unfiltered pass when the project itself moved after the watermark' do
      project = project_with_stale_issue
      project.update_column(:updated_at, 1.hour.ago)

      stub_sync_commit(1.day.ago, watermark: watermark)

      expect_full_sync(project, since: nil)

      worker.perform
    end

    it 'asks for an unfiltered pass when the last commit carries no watermark' do
      project = project_with_stale_issue

      stub_sync_commit(1.day.ago, watermark: nil)

      expect_full_sync(project, since: nil)

      worker.perform
    end
  end

  # The import side of the nightly. What it must not do is reach ImportWorker,
  # which imports every peer directory on the branch on the authority of the
  # person who pushed them -- an authority the cron does not have and cannot
  # produce. ImportRefreshWorker is bounded instead.
  describe 'the imports it enqueues' do
    it 'refreshes each project that already holds replicas, once' do
      one = create(:project)
      two = create(:project)
      create(:oc_replicated_work_item, project: one, source_instance_uuid: 'peer-a')
      create(:oc_replicated_work_item, project: one, source_instance_uuid: 'peer-b',
        source_path: 'peer-b/issues/1.yml')
      create(:oc_replicated_work_item, project: two, source_instance_uuid: 'peer-a')

      expect(OC::WorkItems::ImportRefreshWorker).to receive(:perform_in).with(anything, one.id).once
      expect(OC::WorkItems::ImportRefreshWorker).to receive(:perform_in).with(anything, two.id).once

      worker.perform
    end

    it 'never enqueues the worker that would import on a pusher authority' do
      create(:oc_replicated_work_item, project: create(:project), source_instance_uuid: 'peer-a')

      expect(OC::WorkItems::ImportWorker).not_to receive(:perform_in)
      expect(OC::WorkItems::ImportWorker).not_to receive(:perform_async)

      worker.perform
    end

    it 'leaves alone a project with no replicas of its own' do
      create(:project)

      expect(OC::WorkItems::ImportRefreshWorker).not_to receive(:perform_in)

      worker.perform
    end
  end
end
