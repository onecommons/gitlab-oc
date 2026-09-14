import { shallowMount } from '@vue/test-utils';
import CiIcon from '~/vue_shared/components/ci_icon/ci_icon.vue';

// OC Change -- a scheduled job reads as "upcoming" rather than "delayed".
describe('CiIcon status text', () => {
  const createComponent = (text) =>
    shallowMount(CiIcon, {
      propsData: {
        status: { icon: 'status_scheduled', text, group: 'scheduled', detailsPath: '/' },
        showStatusText: true,
      },
    });

  it('relabels a delayed status', () => {
    expect(createComponent('delayed').vm.statusText).toBe('upcoming');
  });

  it('leaves every other status alone', () => {
    expect(createComponent('running').vm.statusText).toBe('running');
  });
});
