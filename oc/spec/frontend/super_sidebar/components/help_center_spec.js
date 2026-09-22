import { GlDisclosureDropdownGroup } from '@gitlab/ui';
import { mountExtended } from 'helpers/vue_test_utils_helper';
import HelpCenter from 'oc/super_sidebar/components/help_center.vue';
import { helpPagePath } from '~/helpers/help_page_helper';
import { helpDocsPath } from '~/lib/utils/path_helpers/help';

describe('HelpCenter', () => {
  let wrapper;

  const sidebarData = {
    show_version_check: false,
    support_path: '/onecommons/support',
    compare_plans_url: '/pricing',
    display_whats_new: false,
  };

  const createWrapper = () =>
    mountExtended(HelpCenter, {
      propsData: { sidebarData },
      provide: { isSaas: false, isIconOnly: false },
    });

  const findGroups = () => wrapper.findAllComponents(GlDisclosureDropdownGroup);
  const itemsOf = (index) => findGroups().at(index).props('group').items;

  beforeEach(() => {
    wrapper = createWrapper();
  });

  it('keeps only the links that mean something in the fork', () => {
    expect(itemsOf(0).map((item) => item.href)).toEqual([
      helpPagePath(),
      '/onecommons/support',
      helpDocsPath(),
    ]);
  });

  it('keeps the keyboard shortcuts action', () => {
    expect(itemsOf(1).map((item) => item.text)).toEqual(['Keyboard shortcuts']);
  });

  it('renders no other group', () => {
    expect(findGroups()).toHaveLength(2);
  });
});
