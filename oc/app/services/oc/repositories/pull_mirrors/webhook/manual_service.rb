# frozen_string_literal: true

module OC
  module Repositories
    module PullMirrors
      module Webhook
        # A mirror of a repository we cannot register a webhook on. The caller
        # is handed the endpoint and secret to configure the hook itself.
        class ManualService < BaseService
          def execute(action)
            case action
            when :create, :update
              success({ url: fetch_endpoint_url, secret: generate_validation_token, events: ['push'] })
            when :delete
              clear_validation_token

              success({ url: fetch_endpoint_url, events: ['push'] })
            end
          end
        end
      end
    end
  end
end
