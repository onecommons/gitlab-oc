# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Projects::UpdateService, feature_category: :source_code_management do
  let_it_be(:owner) { create(:user, :with_namespace) }

  def update_project(project, params)
    described_class.new(project, owner, params).execute
  end

  def opted_in_private_project
    create(:project, :private, namespace: owner.namespace).tap do |project|
      project.enable_work_items_sync!(true)
      project.include_work_items_sync_confidential!(true)
    end
  end

  context 'when a project that syncs confidential content becomes visible' do
    it 'rebuilds the branch from scratch when it turns public' do
      project = opted_in_private_project

      expect(OC::WorkItems::FullSyncWorker).to receive(:perform_async).with(project.id, true)

      expect(update_project(project, visibility_level: Gitlab::VisibilityLevel::PUBLIC))
        .to include(status: :success)
    end

    # Internal is a widening too: every signed-in user can read the repository.
    it 'rebuilds when it turns internal' do
      project = opted_in_private_project

      expect(OC::WorkItems::FullSyncWorker).to receive(:perform_async).with(project.id, true)

      update_project(project, visibility_level: Gitlab::VisibilityLevel::INTERNAL)
    end

    it 'rebuilds even when sync has since been disabled, because the branch remains' do
      project = opted_in_private_project
      project.enable_work_items_sync!(false)

      expect(OC::WorkItems::FullSyncWorker).to receive(:perform_async).with(project.id, true)

      update_project(project, visibility_level: Gitlab::VisibilityLevel::PUBLIC)
    end
  end

  context 'when there is nothing published to purge' do
    it 'does nothing for a private project that never opted in' do
      project = create(:project, :private, namespace: owner.namespace)
      project.enable_work_items_sync!(true)

      expect(OC::WorkItems::FullSyncWorker).not_to receive(:perform_async)

      update_project(project, visibility_level: Gitlab::VisibilityLevel::PUBLIC)
    end

    it 'does nothing when an unrelated attribute changes' do
      project = opted_in_private_project

      expect(OC::WorkItems::FullSyncWorker).not_to receive(:perform_async)

      update_project(project, description: 'a new description')
    end

    it 'does nothing when the project was already public' do
      project = create(:project, :public, namespace: owner.namespace)
      project.include_work_items_sync_confidential!(true)

      expect(OC::WorkItems::FullSyncWorker).not_to receive(:perform_async)

      update_project(project, description: 'a new description')
    end

    it 'does nothing when the update fails' do
      project = opted_in_private_project

      expect(OC::WorkItems::FullSyncWorker).not_to receive(:perform_async)

      result = update_project(project, name: '')

      expect(result[:status]).to eq(:error)
      expect(project.reload).to be_private
    end
  end

  # Topics live in a join table, so the model's hook on the project's own
  # columns does not see them.
  describe 'recording a cloudmap metadata change for topics' do
    let!(:project) { create(:project, :public, namespace: owner.namespace) }

    def recorded_topic_changes
      OC::Projects::CloudmapEvent.metadata_changed.where(project: project)
        .select { |row| row.payload['changed'] == %w[topics] }
    end

    it 'records the project when its topics change' do
      update_project(project, topics: 'cloud, blueprint')

      expect(recorded_topic_changes.size).to eq(1)
    end

    it 'does not record the same topics given again' do
      update_project(project, topics: 'cloud')
      update_project(project, topics: 'cloud')

      expect(recorded_topic_changes.size).to eq(1)
    end
  end
end
