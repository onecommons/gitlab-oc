# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Projects::WorkItemsSyncController, feature_category: :source_code_management do
  let_it_be(:project) { create(:project) }
  let_it_be(:maintainer) { create(:user) }
  let_it_be(:developer) { create(:user) }

  before_all do
    project.custom_attributes.create!(key: 'unfurl_type', value: OC::REGULAR_PROJECT)
    project.add_maintainer(maintainer)
    project.add_developer(developer)
  end

  describe 'PUT /:namespace/:project/-/work_items_sync' do
    def put_toggle(user, enabled)
      sign_in(user)
      put project_work_items_sync_path(project), params: { enabled: enabled }
    end

    it 'enables sync and starts a backfill' do
      expect(OC::WorkItems::FullSyncWorker).to receive(:perform_async).with(project.id)

      put_toggle(maintainer, 'true')

      expect(response).to redirect_to(
        project_settings_repository_path(project, anchor: 'js-work-items-sync-settings'))
      expect(flash[:notice]).to include('settings saved')
      expect(project.reload.work_items_sync_opted_in?).to be(true)
    end

    it 'disables sync without a backfill' do
      project.enable_work_items_sync!(true)

      expect(OC::WorkItems::FullSyncWorker).not_to receive(:perform_async)

      put_toggle(maintainer, 'false')

      expect(project.reload.work_items_sync_opted_in?).to be(false)
    end

    it 'turns sync off for a project that is on by default' do
      unfurl_project = create(:project)
      unfurl_project.custom_attributes.create!(key: 'unfurl_type', value: OC::UNFURL_DASHBOARD)
      unfurl_project.add_maintainer(maintainer)
      expect(unfurl_project.work_items_sync_enabled?).to be(true)

      sign_in(maintainer)
      put project_work_items_sync_path(unfurl_project), params: { enabled: 'false' }

      expect(unfurl_project.reload.work_items_sync_enabled?).to be(false)
    end

    it 'opts a private project into confidential content and re-syncs' do
      private_project = create(:project, :private)
      private_project.custom_attributes.create!(key: 'unfurl_type', value: OC::REGULAR_PROJECT)
      private_project.add_maintainer(maintainer)

      expect(OC::WorkItems::FullSyncWorker).to receive(:perform_async).with(private_project.id)

      sign_in(maintainer)
      put project_work_items_sync_path(private_project), params: { enabled: 'true', sync_confidential: '1' }

      expect(private_project.reload.work_items_sync_confidential_included?).to be(true)
      expect(private_project.sync_confidential_work_items?).to be(true)
    end

    it 'opts back out when the box is unchecked, purging the branch history' do
      private_project = create(:project, :private)
      private_project.custom_attributes.create!(key: 'unfurl_type', value: OC::REGULAR_PROJECT)
      private_project.add_maintainer(maintainer)
      private_project.include_work_items_sync_confidential!(true)

      # a plain rebuild would only tombstone the confidential files
      expect(OC::WorkItems::FullSyncWorker).to receive(:perform_async).with(private_project.id, true)

      sign_in(maintainer)
      put project_work_items_sync_path(private_project), params: { enabled: 'true' }

      expect(private_project.reload.work_items_sync_confidential_included?).to be(false)
    end

    it 'does a plain re-sync when the confidential setting did not change' do
      expect(OC::WorkItems::FullSyncWorker).to receive(:perform_async).with(project.id)

      sign_in(maintainer)
      put project_work_items_sync_path(project), params: { enabled: 'true' }
    end

    it 'is not available to developers' do
      put_toggle(developer, 'true')

      expect(response).to have_gitlab_http_status(:not_found)
      expect(project.reload.work_items_sync_opted_in?).to be(false)
    end
  end

  describe 'settings section rendering (GET repository settings)' do
    it 'shows the toggle for regular projects' do
      sign_in(maintainer)

      get project_settings_repository_path(project)

      expect(response).to have_gitlab_http_status(:ok)
      expect(response.body).to include('Work items sync')
      expect(response.body).to include('Enable work items sync')
    end

    it 'shows unfurl projects as on by default, with a way to turn it off' do
      unfurl_project = create(:project)
      unfurl_project.custom_attributes.create!(key: 'unfurl_type', value: OC::UNFURL_DASHBOARD)
      unfurl_project.add_maintainer(maintainer)
      sign_in(maintainer)

      get project_settings_repository_path(unfurl_project)

      expect(response.body).to include('on by default for Unfurl projects')
      expect(response.body).to include('Disable work items sync')
    end

    it 'locks the confidential option on public projects' do
      public_project = create(:project, :public)
      public_project.custom_attributes.create!(key: 'unfurl_type', value: OC::REGULAR_PROJECT)
      public_project.add_maintainer(maintainer)
      sign_in(maintainer)

      get project_settings_repository_path(public_project)

      expect(response.body).to include('never synced on public and internal projects')
      expect(confidential_checkbox(response.body)).to include('disabled')
    end

    it 'offers the confidential opt-in, unchecked, on private projects' do
      private_project = create(:project, :private)
      private_project.custom_attributes.create!(key: 'unfurl_type', value: OC::REGULAR_PROJECT)
      private_project.add_maintainer(maintainer)
      sign_in(maintainer)

      get project_settings_repository_path(private_project)

      expect(response.body).to include('Also sync confidential content')
      expect(response.body).to include('left out by default')

      checkbox = confidential_checkbox(response.body)
      expect(checkbox).not_to include('disabled')
      expect(checkbox).not_to include('checked')
    end

    def confidential_checkbox(body)
      body[/<input[^>]*name="sync_confidential"[^>]*>/] ||
        body[/<input[^>]*sync_confidential[^>]*>/] ||
        raise('no sync_confidential checkbox rendered')
    end
  end
end
