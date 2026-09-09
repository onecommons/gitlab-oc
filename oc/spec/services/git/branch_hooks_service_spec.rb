# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Git::BranchHooksService, feature_category: :source_code_management do
  # Upstream runs this on every branch, so without the override a reference
  # token in a sync commit message would stamp a "mentioned in commit" system
  # note, whose record update triggers another sync writing the same message.
  # Part of that message is the deploy-supplied version trailer.
  describe '#enqueue_process_commit_messages' do
    # A real commit: Commit#to_hash is not a defined instance method, so a
    # verifying double of one cannot be built.
    let(:project) { create(:project, :repository) }

    def service_for(ref:)
      referencing = project.commit
      allow(referencing).to receive(:matches_cross_reference_regex?).and_return(true)

      described_class.new(
        project,
        project.creator,
        change: { oldrev: 'old-revision', newrev: 'new-revision', ref: ref }
      ).tap do |service|
        allow(service).to receive_messages(limited_commits: [referencing], upstream_commit_ids: [],
          default_branch?: false)
      end
    end

    it 'never processes commit messages on the work items sync branch' do
      expect(ProcessCommitWorker).not_to receive(:perform_in)

      service_for(ref: "refs/heads/#{OC::WorkItems::SYNC_BRANCH}").send(:enqueue_process_commit_messages)
    end

    it 'still processes them on other branches' do
      expect(ProcessCommitWorker).to receive(:perform_in)

      service_for(ref: 'refs/heads/main').send(:enqueue_process_commit_messages)
    end

    it 'leaves a reference token in the sync commit message inert' do
      allow(Gitlab).to receive(:revision).and_return('release#12')

      expect(OC::WorkItems.commit_message).to include('#12')
    end
  end

  describe '#create_pipeline' do
    let(:project) { create(:project) }

    def service_for(ref:)
      described_class.new(
        project,
        project.creator,
        change: { oldrev: 'old-revision', newrev: 'new-revision', ref: ref }
      )
    end

    it 'never creates a pipeline for pushes to the work items sync branch' do
      expect(Ci::CreatePipelineService).not_to receive(:new)

      service_for(ref: "refs/heads/#{OC::WorkItems::SYNC_BRANCH}").send(:create_pipeline)
    end

    it 'still creates pipelines for other branches' do
      service = service_for(ref: 'refs/heads/main')
      allow(service).to receive(:pipeline_params).and_return({})

      expect(Ci::CreatePipelineService).to receive(:new)
        .and_return(instance_double(Ci::CreatePipelineService, execute_async: true))

      service.send(:create_pipeline)
    end
  end

  describe '#execute' do
    let(:project) { create(:project, :repository) }

    def service_for(ref:, newrev: project.commit.id)
      described_class.new(
        project,
        project.creator,
        change: { oldrev: Gitlab::Git::SHA1_BLANK_SHA, newrev: newrev, ref: ref }
      )
    end

    it 'starts an import when the work items sync branch is pushed' do
      expect(OC::WorkItems::ImportWorker).to receive(:perform_async).with(project.id, project.creator.id)

      service_for(ref: "refs/heads/#{OC::WorkItems::SYNC_BRANCH}").execute
    end

    it 'does not start one for a deletion of the branch' do
      expect(OC::WorkItems::ImportWorker).not_to receive(:perform_async)

      service_for(ref: "refs/heads/#{OC::WorkItems::SYNC_BRANCH}", newrev: Gitlab::Git::SHA1_BLANK_SHA).execute
    end

    it 'does not start one for any other branch' do
      expect(OC::WorkItems::ImportWorker).not_to receive(:perform_async)

      service_for(ref: 'refs/heads/main').execute
    end
  end

  # A force push reports no file list, so the Unfurl files have to be assumed
  # changed or the project keeps a classification its repository contradicts.
  describe '#invalidated_file_types' do
    let(:project) { create(:project, :repository) }

    def service_for(force_push:)
      described_class.new(
        project,
        project.creator,
        change: { oldrev: 'old-revision', newrev: 'new-revision', ref: 'refs/heads/master' }
      ).tap do |service|
        allow(service).to receive_messages(default_branch?: true, creating_branch?: false,
          modified_file_types: [:readme])
        allow(Gitlab::Checks::ForcePush).to receive(:force_push?).and_return(force_push)
      end
    end

    it 'adds the Unfurl files on a force push' do
      types = service_for(force_push: true).send(:invalidated_file_types)

      expect(types).to include(:unfurl_yaml, :ensemble_template_yaml, :readme)
    end

    it 'leaves an ordinary push reporting only what it changed' do
      types = service_for(force_push: false).send(:invalidated_file_types)

      expect(types).to contain_exactly(:readme)
    end
  end
end
