# frozen_string_literal: true

module Sidebars
  module Explore
    module Menus
      class BlueprintsMenu < ::Sidebars::Menu
        override :link
        def link
          explore_blueprints_path
        end

        override :title
        def title
          _('Blueprints')
        end

        override :sprite_icon
        def sprite_icon
          'applications'
        end

        override :render?
        def render?
          true
        end

        override :active_routes
        def active_routes
          { controller: 'explore/blueprints' }
        end
      end
    end
  end
end
