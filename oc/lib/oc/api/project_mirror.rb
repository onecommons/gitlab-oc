# frozen_string_literal: true

module OC
  module API
    # OC Change -- pull mirroring
    #
    # Upstream's pull mirroring is EE-only, and its webhook endpoint
    # (ee/lib/api/project_mirror.rb) authenticates a SHA-1 signature over a
    # per-project external_webhook_token. This edition signs SHA-256 over a
    # token stored with the project's import credentials instead, so the token
    # is encrypted and is thrown away with them.
    class ProjectMirror < ::API::Base
      feature_category :source_code_management

      rescue_from Octokit::Unauthorized, with: :provider_unauthorized

      helpers do
        # user_project needs an auth token, which a webhook delivery does not
        # carry: it authenticates by signature.
        def project
          @project ||= webhook? ? find_project(params[:id]) : user_project
        end

        def webhook?
          headers['X-Hub-Signature-256'].present?
        end

        # Verifies this is the webhook we registered at import.
        def validate_github_webhook(payload)
          token = project.import_data&.credentials&.dig(:webhook_token)
          return false unless token.present?

          signature = "sha256=#{OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'), token, payload)}"
          Rack::Utils.secure_compare(signature, headers['X-Hub-Signature-256'])
        end

        def gh_client
          @gh_client ||= ::Gitlab::GithubImport::Client.new(
            params[:personal_access_token], host: params[:github_hostname]
          )
        end

        def provider
          :github
        end

        def provider_unauthorized
          error!("Access denied to your #{::Gitlab::ImportSources.title(provider.to_s)} account.", 401)
        end

        def present_hook(result)
          if result[:status] == :success
            return not_modified! if result[:hook] == :not_modified

            present result[:hook]
          else
            render_api_error!(result[:message], result[:http_status])
          end
        end

        # A dashboard is imported from the dashboard template, and must not go
        # on fetching from it. mirror? already excludes a classified dashboard;
        # this covers the window before its repository has been classified.
        def imported_from_dashboard_template?
          project.safe_import_url(masked: false) ==
            ::Gitlab::ProjectTemplate.find(:unfurl_dashboard)&.clone_url
        end

        # Managing the hook mints or clears the secret that authenticates every
        # later fetch, so it takes the same permission as the mirror settings
        # page. user_project alone only proves the caller can *read*, which on
        # a public project is everyone.
        def authorize_manage_mirror_hook!
          authenticate!
          # rubocop:disable Gitlab/Authz/PermissionCheck -- this is upstream's own
          # permission for managing a project's mirrors, enforced identically by
          # Projects::MirrorsController#check_mirror_available!; neither CE nor EE
          # defines a granular alternative.
          authorize! :admin_remote_mirror, user_project
          # rubocop:enable Gitlab/Authz/PermissionCheck
        end

        # A signature-validated delivery carries no CSRF token, and does not
        # need one.
        def verified_request?
          route.origin == '/api/:version/projects/:id/mirror/fetch' ||
            ::Gitlab::RequestForgeryProtection.verified?(env)
        end
      end

      params do
        requires :id, type: String, desc: 'The ID of a project'
      end
      resource :projects, requirements: ::API::NAMESPACE_OR_PROJECT_REQUIREMENTS do
        desc 'Trigger fetch from configured remote repository'
        post ":id/mirror/fetch" do
          break present(currently_mirroring: false) unless project.mirror_enabled?

          if webhook?
            payload_raw = request.body.read
            forbidden! unless validate_github_webhook(payload_raw)

            payload = ::Gitlab::Json::SafeParser.parse(payload_raw)
            updated_ref = payload['ref'].delete_prefix('refs/heads/') if payload['ref']

            if headers['X-Github-Event'] == 'ping'
              break present ping: 'pong', new_head_commit: project.repository&.head_commit&.id
            end
          else
            authenticate!

            # TODO: allow setting branch name from api param for gl token
          end

          updated_ref ||= project.default_branch_or_main

          project.ensure_repository

          break render_api_error!('Project is not a remote import', 400) if imported_from_dashboard_template?

          # unsafe_import_url carries the credentials kept from the import, so
          # there is no authorization header to build.
          begin
            old_ref_commit = project.repository.commit(updated_ref)&.id
            project.repository.fetch_as_mirror(project.unsafe_import_url, forced: true)
            new_ref_commit = project.repository.commit(updated_ref)&.id
          rescue StandardError
            break render_api_error!('Failed to fetch changes', 500)
          end

          # issue #862
          # After updating a branch, kick off its CI pipeline. GitHub can deliver
          # the same webhook more than once, so do not create another pipeline
          # when this fetch left that branch at the same commit.
          if old_ref_commit != new_ref_commit
            begin
              CreatePipelineWorker.perform_async(project.id, project.owner.id, updated_ref, :push)
            rescue StandardError
              break render_api_error!('Failed to start pipelines', 500)
            end
          end

          present new_head_commit: project.repository.head_commit.id
        end

        #
        # mirror webhook management endpoints
        #

        desc 'Manage remote webhooks for pull mirroring'
        params do
          requires :personal_access_token, type: String, desc: 'Github personal access token'
        end
        post ":id/mirror/hook/github" do
          authorize_manage_mirror_hook!

          result = OC::Repositories::PullMirrors::Webhook::GithubService
            .new(user_project, gh_client, repo_name: user_project.import_source)
            .execute(:create)

          present_hook(result)
        end
        params do
          requires :personal_access_token, type: String, desc: 'Github personal access token'
        end
        delete ":id/mirror/hook/github" do
          authorize_manage_mirror_hook!

          result = OC::Repositories::PullMirrors::Webhook::GithubService
            .new(user_project, gh_client, repo_name: user_project.import_source)
            .execute(:delete)

          present_hook(result)
        end

        post ":id/mirror/hook/manual" do
          authorize_manage_mirror_hook!

          present_hook(OC::Repositories::PullMirrors::Webhook::ManualService.new(user_project).execute(:create))
        end
        delete ":id/mirror/hook/manual" do
          authorize_manage_mirror_hook!

          present_hook(OC::Repositories::PullMirrors::Webhook::ManualService.new(user_project).execute(:delete))
        end
      end
    end
  end
end
