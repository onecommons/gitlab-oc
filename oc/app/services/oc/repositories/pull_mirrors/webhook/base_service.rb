# frozen_string_literal: true

module OC
  module Repositories
    module PullMirrors
      module Webhook
        # OC Change -- pull mirroring
        # Manages the webhook on the upstream repository that POSTs to
        # /projects/:id/mirror/fetch whenever that repository is pushed to.
        class BaseService < ::BaseService
          attr_reader :client

          def initialize(project, client = nil, params = {})
            @project = project
            @client = client
            @params = params
          end

          def fetch_endpoint_url
            "#{Settings.gitlab.url}/api/v4/projects/#{project.id}/mirror/fetch"
          end

          private

          def success(hook_data)
            super().merge(hook: hook_data)
          end

          # The token goes in with the import credentials, so it is encrypted
          # and it is thrown away with them.
          def generate_validation_token
            token = SecureRandom.hex(20)

            project.build_or_assign_import_data(credentials: { webhook_token: token })
            project.import_data.save!

            token
          end

          def clear_validation_token
            project.build_or_assign_import_data(credentials: { webhook_token: nil })
            project.import_data.save!
          end
        end
      end
    end
  end
end
