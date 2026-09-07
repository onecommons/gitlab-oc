# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Work items sync API', feature_category: :source_code_management do
  include ApiHelpers

  let_it_be(:project) { create(:project) }
  let_it_be(:maintainer) { create(:user) }
  let_it_be(:developer) { create(:user) }

  before_all do
    project.custom_attributes.create!(key: 'unfurl_type', value: OC::REGULAR_PROJECT)
    project.add_maintainer(maintainer)
    project.add_developer(developer)
  end

  describe 'POST /projects/:id/work_items_sync' do
    it 'opts the project in and starts a backfill' do
      expect(OC::WorkItems::FullSyncWorker).to receive(:perform_async).with(project.id)

      post api("/projects/#{project.id}/work_items_sync", maintainer), params: { enabled: true }

      expect(response).to have_gitlab_http_status(:ok)
      expect(json_response['work_items_sync_enabled']).to be(true)
      expect(project.reload.work_items_sync_opted_in?).to be(true)
    end

    it 'opts the project out without a backfill' do
      project.enable_work_items_sync!(true)

      expect(OC::WorkItems::FullSyncWorker).not_to receive(:perform_async)

      post api("/projects/#{project.id}/work_items_sync", maintainer), params: { enabled: false }

      expect(response).to have_gitlab_http_status(:ok)
      expect(json_response['work_items_sync_enabled']).to be(false)
      expect(project.reload.work_items_sync_opted_in?).to be(false)
    end

    it 'opts a private project into confidential content when asked' do
      private_project = create(:project, :private)
      private_project.add_maintainer(maintainer)

      post api("/projects/#{private_project.id}/work_items_sync", maintainer),
        params: { enabled: true, sync_confidential: true }

      expect(response).to have_gitlab_http_status(:ok)
      expect(json_response['work_items_sync_confidential']).to be(true)
      expect(private_project.reload.work_items_sync_confidential_included?).to be(true)
    end

    it 'leaves confidential content out by default' do
      post api("/projects/#{project.id}/work_items_sync", maintainer), params: { enabled: true }

      expect(json_response['work_items_sync_confidential']).to be(false)
      expect(project.reload.work_items_sync_confidential_included?).to be(false)
    end

    it 'leaves the confidential setting alone when the param is omitted' do
      project.include_work_items_sync_confidential!(true)

      post api("/projects/#{project.id}/work_items_sync", maintainer), params: { enabled: true }

      expect(project.reload.work_items_sync_confidential_included?).to be(true)
    end

    it 'purges the branch history when confidential syncing is turned off' do
      private_project = create(:project, :private)
      private_project.add_maintainer(maintainer)
      private_project.include_work_items_sync_confidential!(true)

      expect(OC::WorkItems::FullSyncWorker).to receive(:perform_async).with(private_project.id, true)

      post api("/projects/#{private_project.id}/work_items_sync", maintainer),
        params: { enabled: true, sync_confidential: false }

      expect(private_project.reload.sync_confidential_work_items?).to be(false)
    end

    it 'is forbidden for developers' do
      post api("/projects/#{project.id}/work_items_sync", developer), params: { enabled: true }

      expect(response).to have_gitlab_http_status(:forbidden)
      expect(project.reload.work_items_sync_opted_in?).to be(false)
    end

    it 'requires the enabled param' do
      post api("/projects/#{project.id}/work_items_sync", maintainer)

      expect(response).to have_gitlab_http_status(:bad_request)
    end
  end
end
