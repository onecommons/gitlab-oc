# frozen_string_literal: true

module Sidebars
  module Help
    # The entries are anchors into one page, so no route tells them apart and
    # every menu item carries an empty active_routes. The sections do claim
    # routes, which is what keeps them open. They carry icons because the
    # collapsed sidebar shows nothing else.
    class Panel < ::Sidebars::Panel
      override :configure_menus
      def configure_menus
        add_menu(::Sidebars::Help::Menus::IntroductionMenu.new(context))
        add_menu(::Sidebars::Help::Menus::UserGuidesMenu.new(context))
        add_menu(::Sidebars::Help::Menus::DeveloperGuideMenu.new(context))
      end

      override :aria_label
      def aria_label
        _('Help')
      end

      override :super_sidebar_context_header
      def super_sidebar_context_header
        aria_label
      end
    end
  end
end
