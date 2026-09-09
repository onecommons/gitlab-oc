# frozen_string_literal: true

module API
  class UnfurlAccessToken < ::API::Base
    # The token is handed to the Unfurl server so a deployment can push its
    # results back, and is stored on the user so the next page load reuses it.
    TOKEN_ATTRIBUTE_KEY = 'unfurl_git_token'
    TOKEN_SCOPES = %w[read_repository write_repository].freeze
    TOKEN_LIFETIME = 7.days

    feature_category :system_access

    before { authenticate! }

    resource :unfurl_access_token do
      desc 'Retrieve the access token Unfurl uses for git access' do
        detail 'Creates one if the user has none, or if the stored one has expired.'
        success code: 200
        failure [
          { code: 401, message: 'Unauthorized' },
          { code: 422, message: 'Unprocessable entity' }
        ]
        tags %w[personal_access_tokens]
      end
      route_setting :authorization, permissions: :create_personal_access_token, boundary_type: :user
      # rubocop: disable CodeReuse/ActiveRecord -- lib/api reads records directly
      get do
        attribute = current_user.custom_attributes.find_or_initialize_by(key: TOKEN_ATTRIBUTE_KEY)
        id, token = attribute.value&.split('|')
        expired = current_user.personal_access_tokens.find_by(id: id) if id.present?

        unless expired&.active?
          response = ::PersonalAccessTokens::CreateService.new(
            current_user: current_user,
            target_user: current_user,
            organization_id: Current.organization.id,
            params: {
              name: ::OC::GIT_TOKEN_NAME,
              scopes: TOKEN_SCOPES,
              expires_at: TOKEN_LIFETIME.from_now.to_date.iso8601
            }
          ).execute

          render_api_error!(response.message, response.http_status || :unprocessable_entity) if response.error?

          created = response.payload[:personal_access_token]

          # Mark the expiry mails delivered at creation so the notification
          # workers leave a token the user never asked for alone.
          created.update!(expire_notification_delivered: true, after_expiry_notification_delivered: true)

          id = created.id
          token = created.token
          attribute.update!(value: "#{id}|#{token}")

          expired&.destroy!
        end

        present id: id.to_i, token: token
      end
      # rubocop: enable CodeReuse/ActiveRecord
    end
  end
end
