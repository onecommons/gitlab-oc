# frozen_string_literal: true

module OC
  module API
    module Projects
      extend ActiveSupport::Concern

      prepended do
        helpers do
          def dashboard_finder_params
            project_finder_params.merge(unfurl_type: ::OC::UNFURL_DASHBOARD)
          end
        end

        # The dashboards a user can act on, for the dashboard picker.
        resource :dashboards do
          before { authenticate! }

          desc 'List the dashboards visible to the authenticated user' do
            detail 'Lists the dashboard projects the authenticated user has at least the given access level on.'
            success code: 200, model: ::API::Entities::BasicProjectDetails
            failure [{ code: 401, message: '401 Unauthorized' }]
            tags %w[projects]
          end
          params do
            use :collection_params
            use :statistics_params

            # rubocop: disable API/AccessLevelStringType -- mirrors /projects, and oc-pages sends numbers
            optional :min_access_level,
              type: Integer,
              values: ::Gitlab::Access.all_values,
              default: ::Gitlab::Access::MAINTAINER,
              desc: 'Limit by minimum access level of authenticated user'
            # rubocop: enable API/AccessLevelStringType
          end
          get feature_category: :groups_and_projects do
            present_projects ::ProjectsFinder.new(
              current_user: current_user, params: dashboard_finder_params
            ).execute
          end
        end

        resource :projects, requirements: ::API::NAMESPACE_OR_PROJECT_REQUIREMENTS do
          desc 'Enable or disable syncing work items into the gitlab-work-items branch'
          params do
            requires :enabled, type: Grape::API::Boolean, desc: 'Whether to sync work items'
            optional :sync_confidential, type: Grape::API::Boolean,
              desc: 'Also sync confidential issues and internal notes (private projects only, off by default)'
          end
          post ':id/work_items_sync', feature_category: :source_code_management do
            authorize_admin_project

            was_syncing_confidential = user_project.sync_confidential_work_items?

            user_project.enable_work_items_sync!(params[:enabled])

            unless params[:sync_confidential].nil?
              user_project.include_work_items_sync_confidential!(params[:sync_confidential])
            end

            if was_syncing_confidential && !user_project.sync_confidential_work_items?
              OC::WorkItems.purge_confidential_history(user_project, was_syncing_confidential)
            elsif user_project.work_items_sync_enabled?
              OC::WorkItems::FullSyncWorker.perform_async(user_project.id)
            end

            status 200
            {
              work_items_sync_opted_in: user_project.work_items_sync_opted_in?,
              work_items_sync_enabled: user_project.work_items_sync_enabled?,
              work_items_sync_confidential: user_project.sync_confidential_work_items?
            }
          end
        end
      end
    end
  end
end
