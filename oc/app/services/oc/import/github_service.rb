# frozen_string_literal: true

module OC
  module Import
    module GithubService
      extend ActiveSupport::Concern
      extend ::Gitlab::Utils::Override

      # OC Change -- pull mirroring
      # Register the webhook that keeps the import up to date. Gitea imports
      # come through this service too, on a legacy client that has no octokit
      # reader, so they are left alone.
      override :execute
      def execute(access_params, provider)
        result = super
        return result unless provider == :github && mirroring_requested? && result[:status] == :success

        project = result[:project]
        project.build_or_assign_import_data(data: { webhook_type: 'github' })
        project.import_data.save!

        hook = OC::Repositories::PullMirrors::Webhook::GithubService
          .new(project, client, repo_name: repo[:full_name])
          .execute(:create)

        return result if hook[:status] == :success

        # The project imported; only the hook failed. Reporting that as a
        # failed import, which is what 15.11 did, loses the project.
        result.merge(warning: hook[:message])
      end
    end
  end
end
