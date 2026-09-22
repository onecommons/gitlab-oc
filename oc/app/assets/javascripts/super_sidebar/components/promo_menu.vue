<script>
import CePromoMenu from '~/super_sidebar/components/promo_menu.vue';

// This is a false violation of @gitlab/no-runtime-template-compiler, since it
// extends a valid Vue single file component.
// eslint-disable-next-line @gitlab/no-runtime-template-compiler
export default {
  name: 'PromoMenu',
  extends: CePromoMenu,
  computed: {
    // Upstream's only entry is Explore, which the topbar's Blueprints link
    // already covers. Below `sm` that link is hidden, and this dropdown is where
    // a signed-out visitor still reaches the fork's sections.
    //
    // Never empty: when the group's slot renders nothing GlDisclosureDropdownGroup
    // falls back to `group.items`, and `group` is null here.
    // eslint-disable-next-line vue/no-unused-properties -- Overrides CE items
    items() {
      const links = this.sidebarData.edition_topbar_links;

      return links?.length ? links : [this.exploreItem];
    },
    // The wide row beside the logo is edition_topbar_links' job.
    // eslint-disable-next-line vue/no-unused-properties -- Overrides CE visibleItems
    visibleItems() {
      return [];
    },
  },
};
</script>
