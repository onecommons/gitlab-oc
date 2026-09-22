import { GlDisclosureDropdown } from '@gitlab/ui';
import { mountExtended } from 'helpers/vue_test_utils_helper';
import PromoMenu from 'oc/super_sidebar/components/promo_menu.vue';

describe('PromoMenu', () => {
  let wrapper;

  const editionTopbarLinks = [
    { text: 'Dashboard', href: '/home' },
    { text: 'Blueprints', href: '/explore/blueprints' },
  ];

  const createWrapper = (sidebarData = {}) =>
    mountExtended(PromoMenu, {
      propsData: { sidebarData, pricingUrl: '/pricing' },
      provide: { isSaas: false },
    });

  const findDropdown = () => wrapper.findComponent(GlDisclosureDropdown);

  it('offers the fork sections in the narrow dropdown, not Explore', () => {
    wrapper = createWrapper({ edition_topbar_links: editionTopbarLinks });

    expect(findDropdown().props('items')).toEqual(editionTopbarLinks);
  });

  it('leaves the wide row to edition_topbar_links', () => {
    wrapper = createWrapper({ edition_topbar_links: editionTopbarLinks });

    expect(wrapper.findByTestId('menu').findAll('li')).toHaveLength(0);
  });

  // An empty group renders its own fallback, which reads a prop this dropdown
  // does not pass.
  it('keeps upstream’s entry rather than leaving the dropdown empty', () => {
    wrapper = createWrapper();

    expect(findDropdown().props('items')).toEqual([{ href: '/explore', text: 'Explore' }]);
  });
});
