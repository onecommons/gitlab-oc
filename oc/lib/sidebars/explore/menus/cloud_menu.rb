# frozen_string_literal: true

module Sidebars
  module Explore
    module Menus
      class CloudMenu < ::Sidebars::Menu
        override :link
        def link
          public_cloud_path
        end

        override :title
        def title
          _('Cloud')
        end

        override :sprite_icon
        def sprite_icon
          'cloud-gear'
        end

        override :render?
        def render?
          true
        end

        override :active_routes
        def active_routes
          { controller: 'public_cloud' }
        end
      end
    end
  end
end
