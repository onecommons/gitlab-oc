# frozen_string_literal: true

# OC Change #1082 -- blueprints are the fork's public discovery page. The tabs
# are client-side routes, so every one of them renders index.
module Explore
  class BlueprintsController < Explore::ApplicationController
    feature_category :groups_and_projects
    urgency :low, [:index]

    def index
      response.headers['Link'] = %(<#{canonical_url}>; rel="canonical")
    end

    private

    def canonical_url
      URI.join(::Gitlab.config.gitlab.url, explore_blueprints_path).to_s
    end
  end
end
