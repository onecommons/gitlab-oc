# frozen_string_literal: true

module OC
  module Import
    module GithubService
      extend ActiveSupport::Concern
      extend ::Gitlab::Utils::Override

      # OC Change -- pull mirroring
      # Record the request to mirror and register the webhook that keeps the
      # import up to date. Gitea imports come through this service too, on a
      # legacy client with no octokit reader and nothing to hook, so they are
      # left alone -- and left unflagged, or they would claim to be mirrors
      # that nothing mirrors.
      override :execute
      def execute(access_params, provider)
        result = super
        return result unless provider == :github && mirroring_requested? && result[:status] == :success

        project = result[:project]
        set_mirror_flag(project)

        hook = OC::Repositories::PullMirrors::Webhook::GithubService
          .new(project, client, repo_name: repo[:full_name])
          .execute(:create)

        return result if hook[:status] == :success

        # The project imported; only the hook failed. Reporting that as a
        # failed import, which is what 15.11 did, loses the project.
        result.merge(warning: hook[:message])
      end

      private

      # OC Change -- mirroring by default
      # TODO: don't enable this by default once we get the settings pane finished
      def mirroring_requested?
        ::Gitlab::Utils.to_boolean(params[:enable_mirroring], default: true)
      end

      # OC Change #863 -- pull mirroring
      # There is no `mirror` column to set: upstream's is gated on an EE
      # feature, so the request is recorded in the import data instead.
      def set_mirror_flag(project)
        project.build_or_assign_import_data(
          data: { is_mirror: true, mirror_enabled: true, webhook_type: 'github' }
        )
        project.import_data.save!
      end
    end
  end
end
