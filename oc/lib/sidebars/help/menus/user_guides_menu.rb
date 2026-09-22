# frozen_string_literal: true

module Sidebars
  module Help
    module Menus
      class UserGuidesMenu < ::Sidebars::Menu
        override :configure_menu_items
        def configure_menu_items
          add_item(::Sidebars::MenuItem.new(
            title: _('Getting Started: AWS'),
            link: help_page_path('guides/getting_started_aws.md'),
            active_routes: {},
            item_id: :help_getting_started_aws
          ))
          add_item(::Sidebars::MenuItem.new(
            title: _('Getting Started: Google'),
            link: help_page_path('guides/getting_started_gcp.md'),
            active_routes: {},
            item_id: :help_getting_started_gcp
          ))
        end

        override :title
        def title
          _('User Guides')
        end

        override :sprite_icon
        def sprite_icon
          'book'
        end

        override :active_routes
        def active_routes
          { path: ['help#index', 'help#show'] }
        end
      end
    end
  end
end
