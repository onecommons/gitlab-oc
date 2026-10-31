# frozen_string_literal: true

module OC
  module SidebarsHelper
    extend ::Gitlab::Utils::Override

    # The fork ships neither GitLab's version nor its release announcements, so
    # the help centre's version badge and What's new item have nothing to say.
    override :super_sidebar_shared_context
    def super_sidebar_shared_context(panel:, panel_type:)
      super.merge(display_whats_new: false, show_version_check: false)
    end

    # Upstream has no help panel, so /help fell through to the fallback -- Your
    # Work signed in, Explore signed out. 15.11 gave it its own sidebar.
    override :super_sidebar_nav_panel
    def super_sidebar_nav_panel(nav: nil, user: nil, **)
      return super unless nav == 'help'

      ::Sidebars::Help::Panel.new(
        ::Sidebars::Context.new(
          current_user: user,
          container: nil,
          route_is_active: method(:active_nav_link?),
          is_super_sidebar: true
        )
      )
    end

    # 15.11 had Dashboard | Blueprints | Cloud beside the logo in
    # layouts/header/_default.html.haml, which 19.3 replaced with the topbar.
    override :super_sidebar_context
    def super_sidebar_context(user, group:, project:, panel:, panel_type:)
      super.merge(edition_topbar_links: topbar_links(project), sidebar_overlay: overlay_super_sidebar?)
    end

    private

    def topbar_links(project)
      # `/home` resolves the user's own dashboard, so this needs no lookup here.
      [
        { text: _('Dashboard'), href: unfurl_home_index_path, icon: 'home',
          active: dashboard_section?(project) },
        { text: _('Blueprints'), href: explore_blueprints_path, icon: 'applications',
          active: blueprints_section?(project) },
        # TODO: replace with our own once we add our custom icons
        { text: _('Cloud'), href: public_cloud_path, icon: 'cloud-gear',
          active: controller.instance_of?(PublicCloudController) }
      ]
    end

    # recorded_unfurl_type rather than the predicates: those classify, which
    # writes, and a topbar renders on every GET.
    def dashboard_section?(project)
      project&.recorded_unfurl_type == ::OC::UNFURL_DASHBOARD
    end

    def blueprints_section?(project)
      controller.instance_of?(::Explore::BlueprintsController) ||
        project&.recorded_unfurl_type == ::OC::UNFURL_BLUEPRINT
    end
  end
end
