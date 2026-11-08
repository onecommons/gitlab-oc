# frozen_string_literal: true

module API
  class UnfurlAccessToken < ::API::Base
    # The token is handed to the Unfurl server so a deployment can push its
    # results back. OC::Authn::UnfurlGitTokenService keeps it, encrypted, so
    # the next page load reuses it.

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
      get do
        response = ::OC::Authn::UnfurlGitTokenService
          .for_user(current_user, organization_id: Current.organization.id).execute

        if response.error?
          render_api_error!(response.message, response.reason || response.http_status || :unprocessable_entity)
        end

        present id: response[:id], token: response[:token]
      end
    end
  end
end
