# frozen_string_literal: true

module Sidebars
  module Projects
    module Menus
      # A dashboard project is the Unfurl dashboard, so its panel is 15.11's
      # flat list under the owner's name rather than a repository's sections.
      class UnfurlDashboardMenu < ::Sidebars::StaticMenu
        override :title
        def title
          _('Dashboard')
        end

        override :render?
        def render?
          true
        end

        override :pick_into_super_sidebar?
        def pick_into_super_sidebar?
          true
        end

        override :configure_menu_items
        def configure_menu_items
          add_item(owner_item)
          add_item(item(_('Dashboard'), project_path(project), { path: 'projects#show' }, :oc_overview, 'home'))
          add_item(item(_('Environments'), project_environments_path(project),
            { controller: 'projects/environments' }, :oc_environments, 'environment'))
          add_item(item(_('Deployments'), project_unfurl_deployments_path(project),
            { path: 'projects#deployments' }, :oc_deployments, 'deployments'))

          unless project.empty_repo?
            add_item(item(_('Repository'), project_tree_path(project, context.current_ref),
              { controller: %w[tree blob blame edit_tree new_tree find_file commits commit branches tags] },
              :oc_repository, 'branch'))
          end

          # rubocop:disable Gitlab/Authz/PermissionCheck -- the check SettingsMenu makes
          if can?(context.current_user, :admin_project, project)
            add_item(item(_('Settings'), edit_project_path(project),
              { path: 'projects#edit', controller: %w[projects/settings/repository projects/settings/ci_cd] },
              :oc_settings, 'settings'))
          end
          # rubocop:enable Gitlab/Authz/PermissionCheck

          true
        end

        private

        def project
          context.project
        end

        def owner_item
          namespace = project.namespace

          ::Sidebars::MenuItem.new(
            title: namespace.owner&.name || namespace.name,
            link: polymorphic_path(namespace.owner || namespace),
            active_routes: {},
            item_id: :oc_owner,
            avatar: namespace.owner&.avatar_url || namespace.avatar_url,
            entity_id: namespace.id
          )
        end

        def item(title, link, active_routes, item_id, icon)
          ::Sidebars::MenuItem.new(title: title, link: link, active_routes: active_routes, item_id: item_id,
            sprite_icon: icon)
        end
      end
    end
  end
end
