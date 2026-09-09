# frozen_string_literal: true

module Sidebars
  module YourWork
    module Menus
      class BlueprintsMenu < ::Sidebars::Menu
        override :link
        def link
          blueprints_dashboard_projects_path
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
          !!context.current_user
        end

        override :active_routes
        def active_routes
          { path: 'projects#blueprints' }
        end
      end
    end
  end
end
