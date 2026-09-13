# frozen_string_literal: true

module OC
  module Repositories
    module PullMirrors
      module Webhook
        class GithubService < BaseService
          def execute(action)
            case action
            when :create
              success(create)
            when :update
              delete
              success(create)
            when :delete
              success(delete)
            end
          rescue Octokit::Error => e
            github_error(e)
          end

          def repo
            @repo ||= client.repository(params[:repo_name])
          end

          # Octokit hands back Sawyer::Resource, which refuses to read `config`
          # -- the name collides with its own internals. Read it off a hash.
          def existing_hook
            gh_client.hooks(repo[:id]).find do |hook|
              hook.to_h.dig(:config, :url) == fetch_endpoint_url
            end
          end

          private

          def gh_client
            client.octokit
          end

          def create
            return :not_modified if existing_hook

            token = generate_validation_token

            gh_client.create_hook(
              repo[:full_name],
              'web',
              {
                url: fetch_endpoint_url,
                content_type: 'json',
                secret: token
              },
              {
                events: ['push'],
                active: true
              }
            ).to_h
          end

          def delete
            hook = existing_hook
            return :not_modified unless hook

            clear_validation_token

            gh_client.remove_hook(repo[:full_name], hook.to_h[:id])
          end

          def github_error(exception)
            error(
              format(_('Webhook creation failed due to a GitHub error: %{original}'),
                original: exception.response_body),
              :unprocessable_entity
            )
          end
        end
      end
    end
  end
end
