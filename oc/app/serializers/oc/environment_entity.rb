# frozen_string_literal: true

module OC
  # OC Change #364 -- the dashboard app routes an environment by name, and the
  # fork's environments controller resolves either, so a link carrying the id
  # lands on a page the app cannot resolve.
  #
  # Only for callers that ask: the environments index serializes a page of
  # environments at a time, and a classification read per row is an N+1 on a
  # page every GitLab project has.
  module EnvironmentEntity
    extend ActiveSupport::Concern

    prepended do
      unexpose :environment_path
      expose :environment_path do |environment, options|
        if options[:oc_dashboard_link] && ::OC::EnvironmentEntity.route_by_name?(environment)
          project_environment_path(environment.project, environment.name)
        else
          project_environment_path(environment.project, environment)
        end
      end
    end

    # recorded_unfurl_type rather than unfurl_type_without_recording: the latter
    # falls back to a Gitaly call and reads repository files, which does not
    # belong in a serializer. A dashboard whose job has deployed has long been
    # classified.
    def self.route_by_name?(environment)
      return false unless environment.project&.recorded_unfurl_type == ::OC::UNFURL_DASHBOARD

      # A name with a slash in it would not survive the route segment.
      environment.name.exclude?('/')
    end
  end
end
