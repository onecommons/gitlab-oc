import { GlButton, GlButtonGroup, GlLink } from '@gitlab/ui';
import { mountExtended } from 'helpers/vue_test_utils_helper';
import TopicBadges from '~/vue_shared/components/topic_badges.vue';
import BlueprintsListItem from 'oc/explore/blueprints/components/blueprints_list_item.vue';

describe('BlueprintsListItem', () => {
  let wrapper;

  const project = {
    id: 7,
    name: 'minecraft',
    nameWithNamespace: 'onecommons / blueprints / minecraft',
    namespace: { id: 'gid://gitlab/Group/2', fullName: 'onecommons / blueprints' },
    fullPath: 'onecommons/blueprints/minecraft',
    relativeWebUrl: '/onecommons/blueprints/minecraft',
    avatarUrl: '/-/oc/assets/images/uf-avatar-placeholder-2.svg',
    description: 'A Minecraft server.',
    starCount: 3,
    blueprintDeploymentCount: 12,
    topics: ['Gaming'],
  };

  const createComponent = (props = {}) => {
    wrapper = mountExtended(BlueprintsListItem, { propsData: { project, ...props } });
  };

  const findNamespace = () => wrapper.find('h5');
  const findBadgeGroups = () => wrapper.findAllComponents(GlButtonGroup);
  const findDeploys = () => wrapper.findComponent(GlLink);
  const findStarButtons = () => findBadgeGroups().at(0).findAllComponents(GlButton);

  it('leads with the project avatar', () => {
    createComponent();

    expect(wrapper.find('img').attributes('src')).toBe(project.avatarUrl);
  });

  // GitLab's identicon is a single letter, illegible at tile size.
  it('falls back to an Unfurl placeholder, keyed so it is stable per project', () => {
    createComponent({ project: { ...project, avatarUrl: null } });

    expect(wrapper.find('img').attributes('src')).toBe(
      '/-/oc/assets/images/uf-avatar-placeholder-1.svg',
    );
  });

  it('names the project and its namespace', () => {
    createComponent();

    expect(wrapper.find('h4').text()).toBe('minecraft');
    expect(findNamespace().text()).toBe('onecommons / blueprints /');
  });

  it('drops the namespace where every blueprint shares one', () => {
    createComponent({ showNamespace: false });

    expect(findNamespace().exists()).toBe(false);
  });

  // 15.11 pilled the stars alone and left the deploy count a plain link.
  it('shows the deploy count as a link, with only the stars pilled', () => {
    createComponent();

    expect(findBadgeGroups()).toHaveLength(1);
    expect(findDeploys().text()).toBe('12 Deploys');
    expect(findDeploys().attributes('href')).toBe('/onecommons/blueprints/minecraft');
  });

  it('shows a zero deploy count rather than hiding it', () => {
    createComponent({ project: { ...project, blueprintDeploymentCount: 0 } });

    expect(findDeploys().text()).toBe('0 Deploys');
  });

  it('points both halves of the star badge at the starrers', () => {
    createComponent();

    expect(findStarButtons()).toHaveLength(2);
    findStarButtons().wrappers.forEach((button) => {
      expect(button.attributes('href')).toBe('/onecommons/blueprints/minecraft/-/starrers');
    });
    expect(findStarButtons().at(1).text()).toBe('3');
  });

  it('shows the description and the topics', () => {
    createComponent();

    expect(wrapper.text()).toContain('A Minecraft server.');
    expect(wrapper.findComponent(TopicBadges).props('topics')).toEqual(['Gaming']);
  });

  it('renders without a description or topics', () => {
    createComponent({ project: { ...project, description: null, topics: [] } });

    expect(wrapper.find('p').exists()).toBe(false);
    expect(wrapper.findComponent(TopicBadges).exists()).toBe(false);
  });
});
