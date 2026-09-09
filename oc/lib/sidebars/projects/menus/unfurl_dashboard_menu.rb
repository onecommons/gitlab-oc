# frozen_string_literal: true

module Sidebars
  module Projects
    module Menus
      # A dashboard project is the Unfurl dashboard, so its panel offers the
      # dashboard's own views rather than a repository's.
      class UnfurlDashboardMenu < ::Sidebars::Menu
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
          true
        end

        override :pick_into_super_sidebar?
        def pick_into_super_sidebar?
          true
        end

        override :configure_menu_items
        def configure_menu_items
          add_item(item(_('Overview'), project_path(context.project), { path: 'projects#show' }, :oc_overview))
          add_item(item(_('Environments'), project_environments_path(context.project),
            { controller: 'projects/environments' }, :oc_environments))
          add_item(item(_('Deployments'), project_unfurl_deployments_path(context.project),
            { path: 'projects#deployments' }, :oc_deployments))
          add_item(item(_('Applications'), project_unfurl_applications_path(context.project),
            { path: 'projects#applications' }, :oc_applications))

          true
        end

        private

        def item(title, link, active_routes, item_id)
          ::Sidebars::MenuItem.new(title: title, link: link, active_routes: active_routes, item_id: item_id)
        end
      end
    end
  end
end
