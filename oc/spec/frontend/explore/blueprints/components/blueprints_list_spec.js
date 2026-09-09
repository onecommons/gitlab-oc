import { shallowMountExtended } from 'helpers/vue_test_utils_helper';
import BlueprintsList from 'oc/explore/blueprints/components/blueprints_list.vue';
import BlueprintsListItem from 'oc/explore/blueprints/components/blueprints_list_item.vue';

describe('BlueprintsList', () => {
  let wrapper;

  const items = [{ id: 1 }, { id: 2 }];

  const createComponent = (props = {}) => {
    wrapper = shallowMountExtended(BlueprintsList, { propsData: { items, ...props } });
  };

  const findItems = () => wrapper.findAllComponents(BlueprintsListItem);

  it('renders a tile per blueprint', () => {
    createComponent();

    expect(findItems()).toHaveLength(2);
    expect(findItems().at(0).props('project')).toBe(items[0]);
  });

  it('passes the namespace setting down', () => {
    createComponent({ showNamespace: false });

    expect(findItems().at(0).props('showNamespace')).toBe(false);
  });

  it('keeps the props TabView passes off the list element', () => {
    wrapper = shallowMountExtended(BlueprintsList, {
      propsData: { items },
      attrs: { timestampType: 'createdAt' },
    });

    expect(wrapper.find('ul').attributes('timestamptype')).toBeUndefined();
  });
});
