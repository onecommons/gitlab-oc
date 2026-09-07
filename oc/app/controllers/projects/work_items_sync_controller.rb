# frozen_string_literal: true

# OC Change -- project settings for work items sync
module Projects
  class WorkItemsSyncController < Projects::ApplicationController
    before_action :authorize_admin_project!

    feature_category :source_code_management

    def update
      enabled = Gitlab::Utils.to_boolean(sync_params[:enabled], default: false)
      was_syncing_confidential = project.sync_confidential_work_items?

      project.enable_work_items_sync!(enabled)
      project.include_work_items_sync_confidential!(
        Gitlab::Utils.to_boolean(sync_params[:sync_confidential], default: false))

      if was_syncing_confidential && !project.sync_confidential_work_items?
        # Turning confidential syncing off has to discard the branch history,
        # not just the files. The rebuild that follows re-adds everything else.
        OC::WorkItems.purge_confidential_history(project, was_syncing_confidential)
      elsif project.work_items_sync_enabled?
        # Covers both directions of either setting: the full sync deletes files
        # that must no longer be there and re-creates the ones that must.
        OC::WorkItems::FullSyncWorker.perform_async(project.id)
      end

      redirect_to project_settings_repository_path(project, anchor: 'js-work-items-sync-settings'),
        notice: notice_for(enabled)
    end

    private

    def sync_params
      params.permit(:enabled, :sync_confidential)
    end

    def notice_for(enabled)
      if enabled
        _('Work items sync settings saved. Issues and merge requests are being committed in the background.')
      else
        _('Work items sync disabled.')
      end
    end
  end
end
