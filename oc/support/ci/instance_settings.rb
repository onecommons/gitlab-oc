# frozen_string_literal: true

# What Unfurl Cloud configures on a new instance, as a rails runner script:
#
#   bin/rails runner oc/support/ci/instance_settings.rb
#
# Kept in step with the "Instance settings" section of .ai/oc.md, which
# explains why each setting is here and which of them 19.3 removed. Change
# both together: the CI image runs this file and a developer follows that
# section, and an instance configured two different ways is worse than one
# configured badly.

# rails console. Removed in 19.3, do not re-add: in_product_marketing_emails_enabled
# and suggest_pipeline_enabled are gone from ApplicationSetting -- no attribute,
# no column -- and referencing either raises before anything after it applies.
admin = User.admins.first # not User.first: lowest id is not necessarily an admin

::ApplicationSettings::UpdateService
  .new(ApplicationSetting.current_without_cache, admin, { home_page_url: '' })
  .execute

ApplicationSetting.current_without_cache.update!(
  # identity
  help_page_documentation_base_url: '', # serve oc/doc rather than docs.gitlab.com
  personal_access_token_prefix: 'uc-',

  # accounts
  user_default_external: true,
  require_admin_approval_after_user_signup: false,
  email_confirmation_setting: 'hard',
  invisible_captcha_enabled: true,

  # GitLab's own marketing, out of the UI
  hide_third_party_offers: true,
  whats_new_variant: 'disabled',
  help_page_hide_commercial_content: true,     # the DevSecOps pitch and promo links on /help
  version_check_enabled: false,                # the version badge only -- see below
  duo_features_enabled: false,                 # AI promotion throughout the UI
  user_deactivation_emails_enabled: false,

  # telemetry: stop reporting to version.gitlab.com
  usage_ping_enabled: false,
  usage_ping_generation_enabled: false,        # both, or the worker still runs -- see below
  include_optional_metrics_in_service_ping: false,
  gitlab_product_usage_data_enabled: false,    # jsonb accessor on service_ping_settings

  # Production has every import source its version offers, and a GDK that has
  # been narrowed to a subset renders no GitLab export button on
  # /projects/new#import_project, which the project-import e2e specs need.
  # 19.3 dropped two of production's: `gitlab` (the GitLab.com importer) and
  # `phabricator`.
  import_sources: %w[github bitbucket bitbucket_server fogbugz git gitlab_project gitea manifest],

  # limits
  max_artifacts_size: 1024,
  default_branch_protection: ::Gitlab::Access::PROTECTION_FULL
)

unfurl_server_url =
  ::OC::Repositories::UnfurlServer.browser_url ||
  abort('Neither UNFURL_SERVER_URL nor extra.unfurl_server_url is set; ' \
    'UNFURL_CLOUDMAP_JSON would be a relative path the browser resolves against GitLab.')

# rails console, continuing from above. 'cypress-e2e' is what the fork's
# cypress suite signs up with (OC_INVITE_CODE, with OC_USERNAME/OC_PASSWORD
# unset so it takes the signup path, which is the only one that creates a
# dashboard).
instance_vars = {
  'UNFURL_VALID_INVITE_CODES' => 'cypress-e2e',
  'UNFURL_APPROVE_MATCHING_CODES' => '\Acypress-e2e\z', # single-quoted: double quotes eat the backslashes
  # Fetched by the browser as-is, so it must be absolute. extra.unfurl_server_url
  # is empty while the image builds -- GDK generates config/gitlab.yml and this
  # runs before anything could add to it -- so UNFURL_SERVER_URL carries it in
  # and the interpolation is no longer silently relative.
  'UNFURL_CLOUDMAP_JSON' =>
    "#{unfurl_server_url}" \
    '/types?auth_project=onecommons%2Fstd&cloudmap=onecommons/cloudmap&file=dummy-ensemble.yaml'
}

# with_indifferent_access is not optional: the service looks the record up with
# attributes[:id] but strips it with except('id'), because it is written for
# ActionController::Parameters. A plain Hash misses the lookup and tries to
# create a duplicate key.
attributes = instance_vars.map do |key, value|
  { id: ::Ci::InstanceVariable.find_by(key: key)&.id,
    key: key, value: value, protected: true, masked: false }.compact.with_indifferent_access
end

service = ::Ci::UpdateInstanceVariablesService.new({ variables_attributes: attributes }, admin)
raise service.errors.join(', ') unless service.execute
