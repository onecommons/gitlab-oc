# frozen_string_literal: true

module OC
  module Onboarding
    # Creating the dashboard from its template is far too much work for the
    # signup request: inline it costs about 120 SQL queries, and a controller
    # action is held to 100.
    class CreateDashboardProjectWorker
      include ApplicationWorker

      data_consistency :sticky
      defer_on_database_health_signal :gitlab_main_org
      feature_category :groups_and_projects
      urgency :low
      idempotent!

      def perform(user_id)
        # Creating from a template runs the import path, whose query count
        # upstream tracks in the issue below and exempts the same way in
        # RepositoryImportWorker. Swap in the fork's own issue when there is one.
        ::Gitlab::QueryLimiting.disable!('https://gitlab.com/gitlab-org/gitlab/-/issues/464677')

        user = ::User.find_by_id(user_id)

        user&.create_dashboard_project!
      end
    end
  end
end
