# frozen_string_literal: true

module Sidebars
  module Projects
    module Menus
      class ApplicationBlueprintMenu < ::Sidebars::Menu
        override :link
        def link
          project_overview_path(context.project)
        end

        override :title
        def title
          _('Application Blueprint')
        end

        override :sprite_icon
        def sprite_icon
          'applications'
        end

        override :render?
        def render?
          true
        end

        # The super sidebar rebuilds the panel from its own menus and keeps an
        # old one only if it says so.
        override :pick_into_super_sidebar?
        def pick_into_super_sidebar?
          true
        end

        override :active_routes
        def active_routes
          { path: 'projects#overview' }
        end
      end
    end
  end
end
