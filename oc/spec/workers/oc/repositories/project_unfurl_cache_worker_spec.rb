# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OC::Repositories::ProjectUnfurlCacheWorker, feature_category: :source_code_management do
  let_it_be(:project) { create(:project, :repository) }

  let(:commit) { project.repository.commit }
  let(:oldrev) { commit.parent_ids.first }
  let(:newrev) { commit.id }
  # The commit the ref points at when a job has been overtaken by a later push.
  let(:overtaken) { project.repository.commit(commit.parent_ids.first) }
  let(:worker) { described_class.new }

  def changed_path(path, status = :MODIFIED, old_path: nil)
    Gitlab::Git::ChangedPath.new(
      status: status, path: path, old_path: old_path || path, old_mode: '100644', new_mode: '100644')
  end

  # `head:` is what the ref resolves to when the job runs, which is not always
  # the commit the job was enqueued for -- see the sethead examples below.
  def stub_changes(*paths, head: commit, ref: 'refs/heads/master')
    allow(project.repository).to receive(:find_changed_paths).and_return(paths)
    allow(project.repository).to receive(:commit).with(newrev).and_return(commit)
    allow(project.repository).to receive(:commit).with(ref).and_return(head)
    allow(Project).to receive(:find_by_id).and_call_original
    allow(Project).to receive(:find_by_id).with(project.id).and_return(project)
  end

  def posted_files
    files = nil
    allow(Gitlab::HTTP).to receive(:post) { |_url, opts| files = Gitlab::Json::SafeParser.parse(opts[:body])['files'] }
    yield
    files
  end

  context 'when no Unfurl server is configured' do
    before do
      stub_config(extra: {})
    end

    it 'does nothing at all' do
      expect(Gitlab::HTTP).not_to receive(:post)

      worker.perform(project.id, 'refs/heads/master', oldrev, newrev)
    end
  end

  context 'with an Unfurl server configured' do
    before do
      stub_config(extra: { 'unfurl_server_url' => 'http://unfurl.test' })
    end

    it 'tells the server to re-read an Unfurl file the push touched' do
      stub_changes(changed_path('unfurl.yaml'))

      files = posted_files { worker.perform(project.id, 'refs/heads/master', oldrev, newrev) }

      expect(files).to eq([{ 'path' => 'unfurl.yaml', 'removed' => false }])
    end

    # The point of taking a range rather than the tip commit: a file changed in
    # the first commit of a push and left alone afterwards does not appear in
    # the tip's own diff, but is stale in the server's cache all the same.
    it 'sends every file the push touched in one request' do
      stub_changes(changed_path('unfurl.yaml'), changed_path('sub/ensemble.yaml'))

      expect(Gitlab::HTTP).to receive(:post).once

      worker.perform(project.id, 'refs/heads/master', oldrev, newrev)
    end

    it 'diffs the whole range, not the tip commit' do
      stub_changes(changed_path('unfurl.yaml'))
      allow(Gitlab::HTTP).to receive(:post)

      worker.perform(project.id, 'refs/heads/master', oldrev, newrev)

      # DiffTree defines no ==, so the ids are what gets compared.
      expect(project.repository).to have_received(:find_changed_paths) do |trees|
        expect(trees.first.left_tree_id).to eq(oldrev)
        expect(trees.first.right_tree_id).to eq(newrev)
      end
    end

    # A branch this push created has nothing to diff against.
    it 'diffs against the commit itself when the branch is new' do
      stub_changes(changed_path('unfurl.yaml'))
      allow(Gitlab::HTTP).to receive(:post)

      worker.perform(project.id, 'refs/heads/master', Gitlab::Git::SHA1_BLANK_SHA, newrev)

      expect(project.repository).to have_received(:find_changed_paths).with([newrev])
    end

    it 'reports a deleted Unfurl file under the path it had' do
      stub_changes(changed_path('unfurl.yaml', :DELETED))

      files = posted_files { worker.perform(project.id, 'refs/heads/master', oldrev, newrev) }

      expect(files).to eq([{ 'path' => 'unfurl.yaml', 'removed' => true }])
    end

    # Renames are not detected, so a moved file arrives as this pair -- which
    # is the two cache operations it needs.
    it 'handles a rename as a removal and an addition' do
      stub_changes(changed_path('old.yaml', :DELETED, old_path: 'ensemble.yaml'),
        changed_path('sub/ensemble.yaml', :ADDED))

      files = posted_files { worker.perform(project.id, 'refs/heads/master', oldrev, newrev) }

      expect(files).to contain_exactly(
        { 'path' => 'ensemble.yaml', 'removed' => true },
        { 'path' => 'sub/ensemble.yaml', 'removed' => false })
    end

    it 'ignores files the Unfurl server does not read' do
      stub_changes(changed_path('README.md'))

      expect(Gitlab::HTTP).not_to receive(:post)

      worker.perform(project.id, 'refs/heads/master', oldrev, newrev)
    end

    it 'reads a service template at the root and nested' do
      stub_changes(changed_path('service_template.py'), changed_path('sub/service_template.yaml'))

      files = posted_files { worker.perform(project.id, 'refs/heads/master', oldrev, newrev) }

      expect(files.map { |f| f['path'] })
        .to contain_exactly('service_template.py', 'sub/service_template.yaml')
    end

    # The reason the parameter exists. The server records this commit as the
    # branch's head, and cannot tell an older one from a newer one, so a job
    # that has been overtaken has to keep quiet: a `retry: 3` redelivery can
    # land after the next push.
    describe 'claiming the branch head' do
      it 'claims it when the push is still what the ref points at' do
        stub_changes(changed_path('unfurl.yaml'))

        expect(Gitlab::HTTP).to receive(:post).with(
          anything, hash_including(query: hash_including(sethead: true))
        )

        worker.perform(project.id, 'refs/heads/master', oldrev, newrev)
      end

      it 'keeps quiet when the ref has moved on since the push' do
        # Resolved before stub_changes installs its stubs, so this is a real
        # commit rather than a double of Commit#sha, which is delegated and so
        # invisible to a verifying double.
        stub_changes(changed_path('unfurl.yaml'), head: overtaken)

        expect(Gitlab::HTTP).to receive(:post).with(
          anything, hash_including(query: hash_including(sethead: false))
        )

        worker.perform(project.id, 'refs/heads/master', oldrev, newrev)
      end

      it 'keeps quiet for a tag, which has no head to move' do
        stub_changes(changed_path('unfurl.yaml'), ref: 'refs/tags/v1.0')

        expect(Gitlab::HTTP).to receive(:post).with(
          anything, hash_including(query: hash_including(sethead: false))
        )

        worker.perform(project.id, 'refs/tags/v1.0', oldrev, newrev)
      end

      it 'asks the repository once however many files the push touched' do
        stub_changes(changed_path('unfurl.yaml'), changed_path('ensemble.yaml'))
        allow(Gitlab::HTTP).to receive(:post)

        worker.perform(project.id, 'refs/heads/master', oldrev, newrev)

        expect(project.repository).to have_received(:commit).with('refs/heads/master').once
      end
    end

    it 'does nothing for a project that has gone away' do
      expect(Gitlab::HTTP).not_to receive(:post)

      worker.perform(non_existing_record_id, 'refs/heads/master', oldrev, newrev)
    end
  end
end
