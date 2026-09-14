# frozen_string_literal: true

module OC
  # OC Change #364 -- the job page is where an environment link is followed
  # into the dashboard app, so it is the one caller that asks for the link to
  # carry the environment's name. Upstream's exposure is repeated here because
  # the option has to reach EnvironmentEntity.
  #
  # The module is named for the seam: BuildDetailsEntity prepends
  # 'BuildDetailEntity', singular.
  module BuildDetailEntity
    extend ActiveSupport::Concern

    prepended do
      unexpose :deployment_status
      expose :deployment_status, if: ->(*) { build.interacts_with_environment? } do
        expose :deployment_status, as: :status
        expose :environment_action, as: :action
        expose :persisted_environment, as: :environment do |build, options|
          options.merge(deployment_details: false, oc_dashboard_link: true).then do |opts|
            ::EnvironmentEntity.represent(build.persisted_environment, opts)
          end
        end
      end
    end
  end
end
