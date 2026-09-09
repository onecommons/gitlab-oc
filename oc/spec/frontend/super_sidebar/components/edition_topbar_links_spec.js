import { GlButton } from '@gitlab/ui';
import { mountExtended } from 'helpers/vue_test_utils_helper';
import EditionTopbarLinks from 'oc/super_sidebar/components/edition_topbar_links.vue';
import CeEditionTopbarLinks from '~/super_sidebar/components/edition_topbar_links.vue';

describe('EditionTopbarLinks', () => {
  let wrapper;

  const links = [
    { text: 'Dashboard', href: '/home', icon: 'home', active: false },
    { text: 'Blueprints', href: '/explore/blueprints', icon: 'applications', active: true },
  ];

  const findButtons = () => wrapper.findAllComponents(GlButton);

  it('renders a link per section', () => {
    wrapper = mountExtended(EditionTopbarLinks, { propsData: { links } });

    expect(findButtons().wrappers.map((button) => button.attributes('href'))).toEqual([
      '/home',
      '/explore/blueprints',
    ]);
  });

  it('marks the current section, without Bootstrap’s pill', () => {
    wrapper = mountExtended(EditionTopbarLinks, { propsData: { links } });

    expect(findButtons().at(0).classes('uf-topbar-link-current')).toBe(false);
    expect(findButtons().at(1).classes('uf-topbar-link-current')).toBe(true);
    expect(findButtons().at(1).attributes('aria-current')).toBe('page');
    expect(findButtons().at(1).classes('active')).toBe(false);
  });

  it('renders nothing without links', () => {
    wrapper = mountExtended(EditionTopbarLinks, { propsData: { links: [] } });

    expect(wrapper.find('nav').exists()).toBe(false);
  });

  it('renders nothing in CE', () => {
    wrapper = mountExtended(CeEditionTopbarLinks, { propsData: { links } });

    expect(wrapper.html()).toBe('');
  });
});
