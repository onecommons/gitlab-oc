# frozen_string_literal: true

module OC
  module Sidebars
    module YourWork
      module Panel
        extend ::Gitlab::Utils::Override

        private

        override :add_menus
        def add_menus
          super

          return unless context.current_user

          insert_menu_before(
            ::Sidebars::YourWork::Menus::ProjectsMenu,
            ::Sidebars::YourWork::Menus::DashboardMenu.new(context)
          )
          add_menu(::Sidebars::YourWork::Menus::BlueprintsMenu.new(context))
          add_menu(::Sidebars::YourWork::Menus::CloudMenu.new(context))
        end
      end
    end
  end
end
