<script>
import CeHelpCenter from '~/super_sidebar/components/help_center.vue';

// Upstream's menu is mostly links into gitlab.com -- University, plan
// comparison, the forum, contributing, feedback -- none of which the fork has.
// Tracking labels rather than titles, which are translated.
const KEPT_LINKS = ['help', 'support', 'gitlab_documentation'];

// This is a false violation of @gitlab/no-runtime-template-compiler, since it
// extends a valid Vue single file component.
// eslint-disable-next-line @gitlab/no-runtime-template-compiler
export default {
  name: 'HelpCenter',
  extends: CeHelpCenter,
  computed: {
    // eslint-disable-next-line vue/no-unused-properties -- Overrides CE itemGroups
    itemGroups() {
      const { helpLinks, helpActions } = CeHelpCenter.computed.itemGroups.call(this);

      return {
        helpLinks: {
          items: helpLinks.items.filter((item) =>
            KEPT_LINKS.includes(item.extraAttrs?.['data-track-label']),
          ),
        },
        // Keyboard shortcuts. The version group goes with show_version_check,
        // which the fork turns off.
        helpActions,
      };
    },
  },
};
</script>
