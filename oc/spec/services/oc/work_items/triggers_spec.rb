# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'work items sync triggers', feature_category: :source_code_management do
  let_it_be(:user) { create(:user) }
  let_it_be_with_reload(:project) { create(:project, :repository) }

  before_all do
    project.add_maintainer(user)
  end

  before do
    project.enable_work_items_sync!(true)
  end

  def expect_sync_enqueued(type, user_id)
    expect(OC::WorkItems::SyncWorker).to receive(:perform_in)
      .with(OC::WorkItems.sync_delay, project.id, type, kind_of(Integer), kind_of(Integer), user_id)
  end

  describe 'issue services' do
    it 'enqueues a sync on create' do
      expect_sync_enqueued('Issue', user.id)

      Issues::CreateService
        .new(container: project, current_user: user, params: { title: 'synced issue' }, perform_spam_check: false)
        .execute
    end

    it 'enqueues a sync on update' do
      issue = create(:issue, project: project)

      expect_sync_enqueued('Issue', user.id)

      Issues::UpdateService
        .new(container: project, current_user: user, params: { title: 'new title' })
        .execute(issue)
    end

    it 'enqueues a sync on close' do
      issue = create(:issue, project: project)

      expect_sync_enqueued('Issue', user.id)

      Issues::CloseService.new(container: project, current_user: user).execute(issue)
    end

    it 'enqueues a sync on work item creation' do
      expect_sync_enqueued('Issue', user.id)

      WorkItems::CreateService
        .new(container: project, current_user: user, params: { title: 'a task' }, perform_spam_check: false)
        .execute
    end

    it 'enqueues a sync with the file removal args on deletion' do
      issue = create(:issue, project: project)

      expect(OC::WorkItems::SyncWorker).to receive(:perform_in)
        .with(OC::WorkItems.sync_delay, project.id, 'Issue', issue.id, issue.iid, user.id)

      Issuable::DestroyService.new(container: project, current_user: user).execute(issue)

      expect(issue).to be_destroyed
    end
  end

  # The issue page is the work items app now, and it edits through these
  # services, not the issue ones. A widget edit arrives with no params at all,
  # so this is the case that could skip the hooks without anyone noticing.
  describe 'work item services' do
    let(:work_item) { create(:work_item, project: project) }

    it 'enqueues a sync when only a widget changes' do
      expect_sync_enqueued('Issue', user.id)

      WorkItems::UpdateService
        .new(container: project, current_user: user, params: {},
          widget_params: { description_widget: { description: 'edited in the app' } })
        .execute(work_item)
    end

    it 'enqueues a sync on close' do
      expect_sync_enqueued('Issue', user.id)

      WorkItems::UpdateService
        .new(container: project, current_user: user, params: { state_event: 'close' })
        .execute(work_item)
    end

    # Unlike Issuable::DestroyService this one checks the ability itself, and
    # a Maintainer may not delete.
    it 'enqueues a sync with the file removal args on deletion' do
      owner = project.first_owner

      expect(OC::WorkItems::SyncWorker).to receive(:perform_in)
        .with(OC::WorkItems.sync_delay, project.id, 'Issue', work_item.id, work_item.iid, owner.id)

      expect(WorkItems::DeleteService.new(container: project, current_user: owner).execute(work_item))
        .to be_success
    end
  end

  describe 'merge request services' do
    let(:merge_request) { create(:merge_request, source_project: project, target_project: project) }

    it 'enqueues a sync on close' do
      expect_sync_enqueued('MergeRequest', user.id)

      MergeRequests::CloseService.new(project: project, current_user: user).execute(merge_request)
    end

    it 'never enqueues for an MR whose source branch is the sync branch (would loop forever)' do
      sync_branch_mr = build_stubbed(:merge_request,
        source_project: project, target_project: project,
        source_branch: OC::WorkItems::SYNC_BRANCH)

      expect(OC::WorkItems::SyncWorker).not_to receive(:perform_in)

      OC::WorkItems.enqueue_sync(sync_branch_mr, user)

      expect(OC::WorkItems.syncable?(sync_branch_mr)).to be(false)
    end
  end

  describe 'note services' do
    let_it_be(:issue) { create(:issue, project: project) }

    let(:note) { create(:note, noteable: issue, project: project, author: user) }

    it 'enqueues a sync when a note is post-processed' do
      expect_sync_enqueued('Issue', user.id)

      Notes::PostProcessService.new(note).execute
    end

    it 'enqueues a sync when a note is updated' do
      expect_sync_enqueued('Issue', user.id)

      Notes::UpdateService.new(project, user, note: 'edited').execute(note)
    end

    it 'enqueues a sync when a note is destroyed' do
      expect_sync_enqueued('Issue', user.id)

      Notes::DestroyService.new(project, user).execute(note)
    end

    it 'does not enqueue for notes on other noteables' do
      snippet = create(:project_snippet, project: project)
      snippet_note = create(:note_on_project_snippet, noteable: snippet, project: project)

      expect(OC::WorkItems::SyncWorker).not_to receive(:perform_in)

      Notes::PostProcessService.new(snippet_note).execute
    end
  end

  # Commit notes route to a different file (commit_notes/<sha>.yml) and so to a
  # different worker, keyed by sha rather than by record.
  describe 'commit note services' do
    let(:commit_id) { project.commit.sha }
    let(:note) { create(:note_on_commit, project: project, author: user, commit_id: commit_id) }

    def expect_commit_notes_sync_enqueued(user_id)
      expect(OC::WorkItems::CommitNotesSyncWorker).to receive(:perform_in)
        .with(OC::WorkItems.sync_delay, project.id, commit_id, user_id)
      expect(OC::WorkItems::SyncWorker).not_to receive(:perform_in)
    end

    it 'enqueues a commit notes sync when a note is post-processed' do
      expect_commit_notes_sync_enqueued(user.id)

      Notes::PostProcessService.new(note).execute
    end

    it 'enqueues a commit notes sync when a note is updated' do
      expect_commit_notes_sync_enqueued(user.id)

      Notes::UpdateService.new(project, user, note: 'edited').execute(note)
    end

    # The destroy path must not go looking for the noteable: for a commit note
    # that is a Gitaly lookup, and the commit may be unreachable by then.
    it 'enqueues a commit notes sync when a note is destroyed' do
      note

      expect_commit_notes_sync_enqueued(user.id)

      Notes::DestroyService.new(project, user).execute(note)
    end

    it 'enqueues for a note on a commit that no longer exists' do
      gone = create(:note_on_commit, project: project, author: user,
        commit_id: 'f0c7d1a94e3b6528d0b1f4a27c9e83b5d6a10f42')

      expect(OC::WorkItems::CommitNotesSyncWorker).to receive(:perform_in)
        .with(OC::WorkItems.sync_delay, project.id, gone.commit_id, user.id)

      Notes::DestroyService.new(project, user).execute(gone)
    end
  end

  describe 'award emoji services' do
    let_it_be(:issue) { create(:issue, project: project) }

    it 'enqueues a sync when an emoji is awarded to an issue' do
      expect_sync_enqueued('Issue', user.id)

      AwardEmojis::AddService.new(issue, 'thumbsup', user).execute
    end

    it 'enqueues a sync for the noteable when an emoji is awarded to a note' do
      note = create(:note, noteable: issue, project: project)

      expect_sync_enqueued('Issue', user.id)

      AwardEmojis::AddService.new(note, 'thumbsup', user).execute
    end

    it 'routes an award on a commit note to the commit notes worker' do
      commit_note = create(:note_on_commit, project: project, commit_id: project.commit.sha)

      expect(OC::WorkItems::CommitNotesSyncWorker).to receive(:perform_in)
        .with(OC::WorkItems.sync_delay, project.id, commit_note.commit_id, user.id)

      AwardEmojis::AddService.new(commit_note, 'thumbsup', user).execute
    end

    it 'enqueues a sync when an award is removed' do
      create(:award_emoji, awardable: issue, name: 'thumbsup', user: user)

      expect_sync_enqueued('Issue', user.id)

      AwardEmojis::DestroyService.new(issue, 'thumbsup', user).execute
    end
  end

  describe 'when sync is disabled for the project' do
    before do
      project.enable_work_items_sync!(false)
    end

    it 'does not enqueue' do
      expect(OC::WorkItems::SyncWorker).not_to receive(:perform_in)

      Issues::CreateService
        .new(container: project, current_user: user, params: { title: 'not synced' }, perform_spam_check: false)
        .execute
    end
  end

  # For the importer: it applies an update by rebuilding, and every destroy and
  # create in that rebuild fires one of the triggers above for a file it is
  # about to write itself.
  #
  # An optimization, not a safety mechanism -- a worker in another process
  # cannot see this flag. What stops a concurrent worker doing damage is
  # SyncService#remove refusing to delete a file whose iid still resolves.
  describe 'suppression during an import' do
    it 'enqueues nothing for work through the ordinary services' do
      expect(OC::WorkItems::SyncWorker).not_to receive(:perform_in)

      OC::WorkItems.suppress_sync do
        Issues::CreateService
          .new(container: project, current_user: user, params: { title: 'rebuilt' }, perform_spam_check: false)
          .execute
      end
    end

    it 'covers the commit notes path too, which enqueues a different worker' do
      expect(OC::WorkItems::CommitNotesSyncWorker).not_to receive(:perform_in)

      OC::WorkItems.suppress_sync do
        note = create(:note_on_commit, project: project, commit_id: project.commit.sha)
        Notes::PostProcessService.new(note).execute
      end
    end

    it 'goes back to enqueuing once the block is done' do
      OC::WorkItems.suppress_sync { nil }

      expect_sync_enqueued('Issue', user.id)

      Issues::CreateService
        .new(container: project, current_user: user, params: { title: 'synced again' }, perform_spam_check: false)
        .execute
    end

    # A raise inside the block must not leave the thread suppressed: Sidekiq
    # reuses threads, so the next job on this one would silently stop syncing.
    it 'restores the triggers when the block raises' do
      expect { OC::WorkItems.suppress_sync { raise 'boom' } }.to raise_error('boom')

      expect(OC::WorkItems).not_to be_sync_suppressed
    end

    # Restored rather than cleared, or an inner block would switch the triggers
    # back on for the outer one still running.
    it 'stays suppressed after a nested block finishes' do
      OC::WorkItems.suppress_sync do
        OC::WorkItems.suppress_sync { nil }

        expect(OC::WorkItems).to be_sync_suppressed
      end

      expect(OC::WorkItems).not_to be_sync_suppressed
    end
  end

  # The delay coalesces a burst of edits into one commit, which is right for
  # people and expensive for a test that has to sit through every occurrence
  # of it. It can be shortened per process, and a value that is not a number
  # of seconds is ignored rather than guessed at -- being slow is a nuisance,
  # being instant when somebody typed it wrong hides the coalescing entirely.
  describe '.sync_delay' do
    def with_delay(value)
      stub_env(OC::WorkItems::SYNC_DELAY_VAR, value)

      OC::WorkItems.sync_delay
    end

    it 'waits ten seconds unless the environment says otherwise' do
      expect(OC::WorkItems.sync_delay).to eq(10.seconds)
      expect(with_delay('')).to eq(10.seconds)
    end

    it 'takes a shorter wait, including none at all' do
      expect(with_delay('1')).to eq(1.second)
      expect(with_delay('0.5')).to eq(0.5.seconds)
      expect(with_delay('0')).to eq(0.seconds)
    end

    it 'ignores anything that is not a number of seconds' do
      expect(with_delay('soon')).to eq(10.seconds)
      expect(with_delay('-5')).to eq(10.seconds)
    end

    it 'is what a trigger actually enqueues with' do
      stub_env(OC::WorkItems::SYNC_DELAY_VAR, '2')

      expect(OC::WorkItems::SyncWorker).to receive(:perform_in)
        .with(2.seconds, project.id, 'Issue', kind_of(Integer), kind_of(Integer), user.id)

      Issues::CreateService
        .new(container: project, current_user: user, params: { title: 'synced sooner' }, perform_spam_check: false)
        .execute
    end
  end
end
