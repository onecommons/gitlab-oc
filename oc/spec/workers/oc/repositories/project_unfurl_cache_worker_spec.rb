# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OC::Repositories::ProjectUnfurlCacheWorker, feature_category: :source_code_management do
  let_it_be(:project) { create(:project, :repository) }

  let(:commit) { project.repository.commit }
  # The commit the ref points at when a job has been overtaken by a later push.
  let(:overtaken) { project.repository.commit(commit.parent_ids.first) }
  let(:worker) { described_class.new }

  def diff_file(old_path, new_path, deleted: false)
    instance_double(Gitlab::Diff::File, old_path: old_path, new_path: new_path, deleted_file?: deleted)
  end

  # `head:` is what the ref resolves to when the job runs, which is not always
  # the commit the job was enqueued for -- see the sethead examples below.
  def stub_diffs(*files, head: commit, ref: 'refs/heads/master')
    diffs = instance_double(Gitlab::Diff::FileCollection::Commit, diff_files: files)
    allow(commit).to receive(:diffs).and_return(diffs)
    allow(project.repository).to receive(:commit).with(commit.id).and_return(commit)
    allow(project.repository).to receive(:commit).with(ref).and_return(head)
    allow(Project).to receive(:find_by_id).and_call_original
    allow(Project).to receive(:find_by_id).with(project.id).and_return(project)
  end

  context 'when no Unfurl server is configured' do
    before do
      stub_config(extra: {})
    end

    it 'does nothing at all' do
      expect(Gitlab::HTTP).not_to receive(:post)

      worker.perform(project.id, 'refs/heads/master', commit.id)
    end
  end

  context 'with an Unfurl server configured' do
    before do
      stub_config(extra: { 'unfurl_server_url' => 'http://unfurl.test' })
    end

    it 'tells the server to re-read an Unfurl file the push touched' do
      stub_diffs(diff_file('unfurl.yaml', 'unfurl.yaml'))

      expect(Gitlab::HTTP).to receive(:post).with(
        'http://unfurl.test/populate_cache',
        hash_including(query: hash_including(path: 'unfurl.yaml', removed: false))
      )

      worker.perform(project.id, 'refs/heads/master', commit.id)
    end

    it 'reports a deleted Unfurl file under the path it had' do
      stub_diffs(diff_file('unfurl.yaml', 'unfurl.yaml', deleted: true))

      expect(Gitlab::HTTP).to receive(:post).with(
        anything, hash_including(query: hash_including(path: 'unfurl.yaml', removed: true))
      )

      worker.perform(project.id, 'refs/heads/master', commit.id)
    end

    it 'ignores files the Unfurl server does not read' do
      stub_diffs(diff_file('README.md', 'README.md'))

      expect(Gitlab::HTTP).not_to receive(:post)

      worker.perform(project.id, 'refs/heads/master', commit.id)
    end

    # The reason the parameter exists. The server records this commit as the
    # branch's head, and cannot tell an older one from a newer one, so a job
    # that has been overtaken has to keep quiet: a `retry: 3` redelivery or a
    # slow file in a multi-file push can both land after the next push.
    describe 'claiming the branch head' do
      it 'claims it when the push is still what the ref points at' do
        stub_diffs(diff_file('unfurl.yaml', 'unfurl.yaml'))

        expect(Gitlab::HTTP).to receive(:post).with(
          anything, hash_including(query: hash_including(sethead: true))
        )

        worker.perform(project.id, 'refs/heads/master', commit.id)
      end

      it 'keeps quiet when the ref has moved on since the push' do
        # Resolved before stub_diffs installs its stubs, so this is a real
        # commit rather than a double of Commit#sha, which is delegated and so
        # invisible to a verifying double.
        stub_diffs(diff_file('unfurl.yaml', 'unfurl.yaml'), head: overtaken)

        expect(Gitlab::HTTP).to receive(:post).with(
          anything, hash_including(query: hash_including(sethead: false))
        )

        worker.perform(project.id, 'refs/heads/master', commit.id)
      end

      it 'keeps quiet for a tag, which has no head to move' do
        stub_diffs(diff_file('unfurl.yaml', 'unfurl.yaml'), ref: 'refs/tags/v1.0')

        expect(Gitlab::HTTP).to receive(:post).with(
          anything, hash_including(query: hash_including(sethead: false))
        )

        worker.perform(project.id, 'refs/tags/v1.0', commit.id)
      end

      it 'asks the repository once however many files the push touched' do
        stub_diffs(diff_file('unfurl.yaml', 'unfurl.yaml'),
          diff_file('ensemble.yaml', 'ensemble.yaml'))
        allow(Gitlab::HTTP).to receive(:post)

        worker.perform(project.id, 'refs/heads/master', commit.id)

        expect(project.repository).to have_received(:commit).with('refs/heads/master').once
      end
    end

    it 'does nothing for a project that has gone away' do
      expect(Gitlab::HTTP).not_to receive(:post)

      worker.perform(non_existing_record_id, 'refs/heads/master', commit.id)
    end
  end
end
