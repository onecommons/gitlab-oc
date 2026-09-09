# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'oc routes', feature_category: :groups_and_projects do
  # draw_all loads every edition's config/routes, and config/application.rb
  # unshifts oc/config/routes to the front, so a fork route silently wins
  # dispatch over an upstream one on the same path. Anything listed here is a
  # decision; anything else is an upgrade that quietly took a feature away.
  let(:deliberate_overrides) do
    [
      'GET /explore(.:format)' # the fork leads Explore with blueprints
    ]
  end

  it 'does not shadow an upstream route' do
    shadowed = Rails.application.routes.routes
      .group_by { |route| "#{route.verb} #{route.path.spec}" }
      .filter_map do |path, routes|
        path if routes.any? { |route| fork_route?(route) } && routes.any? { |route| !fork_route?(route) }
      end

    expect(shadowed - deliberate_overrides).to be_empty
  end

  def fork_route?(route)
    route.source_location.to_s.include?('oc/config/routes/')
  end
end
