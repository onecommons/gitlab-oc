# frozen_string_literal: true

module OC
  module Sidebars
    module Projects
      module SuperSidebarPanel
        extend ::Gitlab::Utils::Override

        # The overview is the point of a blueprint project, so it leads the
        # panel rather than sitting where pick_from_old_menus left it.
        override :configure_menus
        def configure_menus
          super

          blueprint = remove_menu(::Sidebars::Projects::Menus::ApplicationBlueprintMenu)
          return unless blueprint

          insert_menu_before(::Sidebars::Projects::SuperSidebarMenus::ManageMenu, blueprint)
        end
      end
    end
  end
end
