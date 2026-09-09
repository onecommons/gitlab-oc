# frozen_string_literal: true

module OC
  module Sidebars
    module Explore
      module Panel
        extend ::Gitlab::Utils::Override

        private

        override :add_menus
        def add_menus
          super

          insert_menu_before(
            ::Sidebars::Explore::Menus::ProjectsMenu,
            ::Sidebars::Explore::Menus::BlueprintsMenu.new(context)
          )
          add_menu(::Sidebars::Explore::Menus::CloudMenu.new(context))
          remove_menu(::Sidebars::Explore::Menus::SnippetsMenu)
        end
      end
    end
  end
end
