# frozen_string_literal: true

module OC
  module Sidebars
    module Projects
      module SuperSidebarPanel
        extend ::Gitlab::Utils::Override

        # The sections a simple-interface user has no use for. They deploy
        # through the dashboard, not through the project's own machinery.
        SIMPLE_INTERFACE_HIDES = [
          ::Sidebars::Projects::SuperSidebarMenus::DeployMenu,
          ::Sidebars::Projects::SuperSidebarMenus::OperationsMenu,
          ::Sidebars::Projects::SuperSidebarMenus::MonitorMenu,
          ::Sidebars::Projects::SuperSidebarMenus::SecureMenu
        ].freeze

        override :configure_menus
        def configure_menus
          super

          lead_with_blueprint_overview
          replace_with_dashboard_menu
          hide_simple_interface_menus
        end

        # The dashboard menu leads with the owner's name instead.
        override :super_sidebar_context_header
        def super_sidebar_context_header
          super unless dashboard?
        end

        private

        def dashboard?
          context.project.recorded_unfurl_type == ::OC::UNFURL_DASHBOARD
        end

        # The overview is the point of a blueprint project, so it leads the
        # panel rather than sitting where pick_from_old_menus left it.
        def lead_with_blueprint_overview
          blueprint = remove_menu(::Sidebars::Projects::Menus::ApplicationBlueprintMenu)
          return unless blueprint

          insert_menu_before(::Sidebars::Projects::SuperSidebarMenus::ManageMenu, blueprint)
        end

        def replace_with_dashboard_menu
          dashboard = remove_menu(::Sidebars::Projects::Menus::UnfurlDashboardMenu)
          @menus = [dashboard] if dashboard # rubocop:disable Gitlab/ModuleWithInstanceVariables -- the panel's own menu list
        end

        def hide_simple_interface_menus
          return unless context.current_user&.external?

          SIMPLE_INTERFACE_HIDES.each { |menu| remove_menu(menu) }
        end
      end
    end
  end
end
