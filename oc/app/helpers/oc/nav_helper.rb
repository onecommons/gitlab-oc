# frozen_string_literal: true

module OC
  module NavHelper
    extend ::Gitlab::Utils::Override

    # Collapsed from the first paint, so the sidebar doesn't flash open; see
    # OC::PageLayoutHelper#overlay_super_sidebar.
    override :page_with_sidebar_class
    def page_with_sidebar_class
      return super unless overlay_super_sidebar?

      super | %w[page-with-super-sidebar-collapsed page-with-super-sidebar-overlay]
    end

    override :super_sidebar_loading_state_class
    def super_sidebar_loading_state_class
      return super unless overlay_super_sidebar?

      ''
    end
  end
end
