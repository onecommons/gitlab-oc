# frozen_string_literal: true

module OC
  module Sidebars
    module Projects
      module Panel
        extend ::Gitlab::Utils::Override

        private

        override :add_menus
        def add_menus
          super

          return unless context.project.recorded_unfurl_type == ::OC::UNFURL_BLUEPRINT

          add_menu(::Sidebars::Projects::Menus::ApplicationBlueprintMenu.new(context))
        end
      end
    end
  end
end
