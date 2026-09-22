# frozen_string_literal: true

module Sidebars
  module Help
    module Menus
      class IntroductionMenu < ::Sidebars::Menu
        override :configure_menu_items
        def configure_menu_items
          add_item(::Sidebars::MenuItem.new(
            title: _('What is Unfurl Cloud?'),
            link: help_path(anchor: 'what-is-unfurl-cloud'),
            active_routes: {},
            item_id: :help_what_is_unfurl_cloud
          ))
          add_item(::Sidebars::MenuItem.new(
            title: _('Why Unfurl Cloud?'),
            link: help_path(anchor: 'why-unfurl-cloud'),
            active_routes: {},
            item_id: :help_why_unfurl_cloud
          ))
        end

        override :title
        def title
          _('Introduction')
        end

        override :sprite_icon
        def sprite_icon
          'information-o'
        end

        # A section only opens when it is active, and the whole table of
        # contents should be readable on the page it describes.
        override :active_routes
        def active_routes
          { path: 'help#index' }
        end
      end
    end
  end
end
