# frozen_string_literal: true

require 'spec_helper'
require_relative '../support/helpers/work_item_sync_paths'

RSpec.describe RepositoryForkWorker, feature_category: :source_code_management do
  include WorkItemSyncPaths

  describe 'work items sync branch cleanup' do
    let(:source_project) { create(:project) }
    let(:target_project) { create(:project, :repository) }
    let(:worker) { described_class.new }

    before do
      allow(worker).to receive(:start_fork).and_return(true)
      allow(worker).to receive(:gitaly_fork!)
      allow(worker).to receive(:link_lfs_objects)
      allow(target_project).to receive(:after_import)
    end

    it 'removes an inherited sync branch after forking' do
      target_project.repository.create_file(
        target_project.first_owner, sync_path('issues/1.yml'), "inherited: true\n",
        message: 'seed', branch_name: OC::WorkItems::SYNC_BRANCH)

      worker.send(:fork_repository, target_project, source_project)

      expect(target_project.repository.branch_exists?(OC::WorkItems::SYNC_BRANCH)).to be(false)
    end

    it 'does nothing when the fork has no sync branch' do
      expect { worker.send(:fork_repository, target_project, source_project) }.not_to raise_error

      expect(target_project.repository.branch_exists?(OC::WorkItems::SYNC_BRANCH)).to be(false)
    end

    it 'does not fail the fork when cleanup errors' do
      allow(target_project.repository).to receive(:branch_exists?).and_raise(StandardError, 'boom')

      expect { worker.send(:fork_repository, target_project, source_project) }.not_to raise_error
    end
  end
end
