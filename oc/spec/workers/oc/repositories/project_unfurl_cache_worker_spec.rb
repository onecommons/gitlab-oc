# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OC::Repositories::ProjectUnfurlCacheWorker, feature_category: :source_code_management do
  let_it_be(:project) { create(:project, :repository) }

  let(:commit) { project.repository.commit }
  let(:worker) { described_class.new }

  def diff_file(old_path, new_path, deleted: false)
    instance_double(Gitlab::Diff::File, old_path: old_path, new_path: new_path, deleted_file?: deleted)
  end

  def stub_diffs(*files)
    diffs = instance_double(Gitlab::Diff::FileCollection::Commit, diff_files: files)
    allow(commit).to receive(:diffs).and_return(diffs)
    allow(project.repository).to receive(:commit).with(commit.id).and_return(commit)
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

    it 'does nothing for a project that has gone away' do
      expect(Gitlab::HTTP).not_to receive(:post)

      worker.perform(non_existing_record_id, 'refs/heads/master', commit.id)
    end
  end
end
