# frozen_string_literal: true

# config/initializers/content_security_policy.rb has already built the policy:
# Rails loads this directory after it.
OC::Repositories::UnfurlServer.allow_in_csp(Rails.application.config.content_security_policy)
