# frozen_string_literal: true

# OC Change -- the cloud account an environment deploys into.
# Upstream stored this in a Kubernetes cluster record written by a creation
# page it has since deleted. The dashboard app draws the forms now; this is
# what they talk to. No credential is ever sent back to the browser: a
# deployment job gets them server-side.
module Projects
  class EnvironmentProvidersController < Projects::ApplicationController
    include InternalRedirect

    before_action :ensure_dashboard!
    before_action :authorize_maintainer!
    before_action :environment

    feature_category :continuous_delivery
    urgency :low

    def show
      provider = environment.unfurl_provider
      return head :not_found unless provider

      render json: represent(provider)
    end

    def update
      case params.permit(:provider)[:provider]
      when 'aws' then update_aws
      when 'gcp' then update_gcp
      else render_error(_('Unknown cloud provider.'))
      end
    end

    def destroy
      environment.unfurl_provider&.destroy
      head :no_content
    end

    # What the CloudFormation stack and the manual instructions need to name a
    # role this instance is allowed to assume.
    def aws_role
      role = aws_role_for_user

      render json: {
        account_id: ::Gitlab::CurrentSettings.eks_account_id,
        external_id: role.role_external_id,
        role_arn: role.role_arn
      }
    end

    def gcp_authorize
      # A path on this origin only, and never a full URL: this is handed to
      # Google and comes back as a redirect target.
      return_to = safe_redirect_path(params.permit(:return_to)[:return_to])
      return render_error(_('Invalid return path.')) unless return_to

      state = ::GoogleApi::CloudPlatform::Client.new_session_key_for_redirect_uri do |key|
        session[key] = return_to
      end
      session[:error_uri] = return_to

      redirect_to google_client(state: state).authorize_url
    rescue ::GoogleApi::Auth::ConfigMissingError
      render_error(_('Google authentication is not configured on this instance.'))
    end

    def gcp_projects
      return render_error(google_sign_in_required) unless google_token

      projects = google_client(token: google_token).list_projects

      render json: projects.map { |project| { project_id: project.project_id, name: project.name } }
    rescue ::Google::Apis::Error => error
      render_error(error.message)
    end

    private

    def update_aws
      role = aws_role_for_user
      attributes = params.permit(:region, :role_arn)
      provider = assign_provider(
        provider: :aws,
        region: attributes[:region],
        role_arn: attributes[:role_arn],
        role_external_ref: role.role_external_id,
        zone: nil, gcp_project: nil, access_token: nil, access_token_expires_at: nil
      )
      return render_invalid(provider) unless provider.valid?

      # Assume the role here rather than at deploy time, so a role that does not
      # trust this instance is reported while the user still has the form open.
      ::OC::Environments::AwsRoleCredentials.new(provider).credentials

      provider.save!
      role.update(role_arn: provider.role_arn, region: provider.region)

      render json: represent(provider)
    # A timeout reaching STS is a NetworkingError rather than a ServiceError,
    # and is the user's answer to give up on or retry, not a 500.
    rescue ::Aws::Errors::MissingCredentialsError, ::Aws::Errors::ServiceError,
      ::Seahorse::Client::NetworkingError => error
      render_error(error.message)
    end

    def update_gcp
      return render_error(google_sign_in_required) unless google_token

      attributes = params.permit(:gcp_project_id, :zone)
      provider = assign_provider(
        provider: :gcp,
        gcp_project: attributes[:gcp_project_id],
        zone: attributes[:zone],
        access_token: google_token,
        access_token_expires_at: Time.zone.at(google_expires_at.to_i),
        region: nil, role_arn: nil, role_external_ref: nil
      )
      return render_invalid(provider) unless provider.save

      render json: represent(provider)
    end

    def assign_provider(attributes)
      provider = environment.unfurl_provider || environment.build_unfurl_provider

      provider.assign_attributes(attributes.merge(project_id: environment.project_id))
      provider
    end

    def represent(provider)
      {
        provider: provider.provider,
        region: provider.region,
        zone: provider.zone,
        gcp_project_id: provider.gcp_project,
        role_arn: provider.role_arn,
        access_token_usable: provider.access_token_usable?
      }
    end

    def render_error(message)
      render json: { message: message }, status: :unprocessable_entity
    end

    def render_invalid(provider)
      render_error(provider.errors.full_messages.to_sentence)
    end

    # The dashboard app is the only caller, and an environment on any other
    # kind of project has no provider panel.
    def ensure_dashboard!
      not_found unless project.unfurl_dashboard?
    end

    # rubocop: disable Gitlab/Authz/PermissionCheck -- no granular permission covers a fork-owned environment setting
    def authorize_maintainer!
      return if can?(current_user, :admin_project, project)

      access_denied!(_('You must be a project maintainer.'))
    end
    # rubocop: enable Gitlab/Authz/PermissionCheck

    # The dashboard app addresses environments by name; a numeric id still works.
    def environment
      id = params.permit(:environment_id)[:environment_id]

      # rubocop: disable CodeReuse/ActiveRecord -- a name lookup the stock finder does not offer
      id.match?(/\A\d+\z/) ? project.environments.find(id) : project.environments.find_by!(name: id)
      # rubocop: enable CodeReuse/ActiveRecord
    end
    strong_memoize_attr :environment

    def aws_role_for_user
      current_user.aws_role || current_user.create_aws_role!
    end

    def google_client(state: nil, token: nil)
      ::OC::Environments::GoogleCloudClient.new(token, callback_google_api_auth_url, state: state)
    end

    # Left in the session by upstream's OAuth callback, as epoch seconds.
    def google_token
      token = session[::GoogleApi::CloudPlatform::Client.session_key_for_token]
      return if token.blank? || google_expires_at.blank?
      # Also rejects a token with less than ten minutes left, which is not
      # enough for the deployment that spends it.
      return unless google_client(token: token).validate_token(google_expires_at)

      token
    end
    strong_memoize_attr :google_token

    def google_expires_at
      session[::GoogleApi::CloudPlatform::Client.session_key_for_expires_at]
    end

    def google_sign_in_required
      _('Sign in with Google again to continue.')
    end
  end
end
