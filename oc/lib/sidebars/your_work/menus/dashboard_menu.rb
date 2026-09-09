# frozen_string_literal: true

module Sidebars
  module YourWork
    module Menus
      class DashboardMenu < ::Sidebars::Menu
        # own_dashboard memoizes on the user, and the sidebar renders once.
        override :link
        def link
          dashboard = context.current_user.own_dashboard

          dashboard ? project_path(dashboard) : unfurl_home_index_path
        end

        override :title
        def title
          _('Dashboard')
        end

        override :sprite_icon
        def sprite_icon
          'home'
        end

        override :render?
        def render?
          !!context.current_user
        end

        override :active_routes
        def active_routes
          { controller: 'unfurl_home' }
        end
      end
    end
  end
end
