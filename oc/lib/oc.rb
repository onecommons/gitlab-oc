# frozen_string_literal: true

module OC
  CACHE_KEY = 'unfurl'
  DEPLOY_META_FILE_NAME = 'unfurl.json'

  UNFURL_DASHBOARD_NAME = 'dashboard'
  # project's enum
  UNFURL_DASHBOARD = 'Home'
  UNFURL_BLUEPRINT = 'ApplicationBluePrint'
  REGULAR_PROJECT = 'Regular'

  DASHBOARD_PROJECT_ON_SIGNUP = {
    template_name: 'unfurl_dashboard', name: 'Dashboard', path: UNFURL_DASHBOARD_NAME,
    description: 'This is your "home" repository for your environment and deployments'
  }.freeze

  BLUEPRINTS_GROUP = 'onecommons/blueprints'
  UNFURL_STD_PROJECT = 'onecommons/std'
  UNFURL_CLOUDMAP_PROJECT = 'onecommons/cloudmap'

  GIT_TOKEN_NAME = 'UNFURL_GIT_ACCESS'

  # A dashboard's deployments push their results back with this token, and
  # nothing rotates it, so it is exempt from expiry. Matched by name, which the
  # caller supplies: anyone able to create a project access token can claim the
  # exemption by using this name. Narrow it to a fork-owned endpoint if that
  # ever matters.
  PROJECT_TOKEN_NAME = 'UNFURL_PROJECT_TOKEN'

  STAGING_URL = 'https://staging.unfurl.cloud'
  def self.staging?
    ::Gitlab.config.gitlab.url == STAGING_URL
  end
end
