# frozen_string_literal: true

module Sidebars
  module Help
    module Menus
      class DeveloperGuideMenu < ::Sidebars::Menu
        override :link
        def link
          help_path(anchor: 'developer-guide')
        end

        override :title
        def title
          _('Developer Guide')
        end

        override :sprite_icon
        def sprite_icon
          'code'
        end

        override :render?
        def render?
          true
        end
      end
    end
  end
end
