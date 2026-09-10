import emptyStateProjectsSvgPath from '@gitlab/svgs/dist/illustrations/empty-state/empty-projects-md.svg?url';
import { __, s__ } from '~/locale';
import ResourceListsEmptyState, {
  TYPES,
} from '~/vue_shared/components/resource_lists/empty_state.vue';
import { formatGraphQLProjects } from '~/vue_shared/components/projects_list/formatter';
import {
  PAGINATION_TYPE_KEYSET,
  SORT_OPTIONS,
  SORT_OPTION_CREATED,
  SORT_OPTION_STARS,
} from '~/groups_projects/constants';
import BlueprintsList from './components/blueprints_list.vue';
import blueprintsQuery from './graphql/queries/blueprints.query.graphql';

// The group that holds the blueprints Unfurl Cloud publishes itself.
export const VERIFIED_NAMESPACE_PATH = 'onecommons/blueprints';

// A blueprint with no avatar gets an Unfurl placeholder rather than GitLab's
// identicon, which is illegible at tile size. Keyed on the id's last digit, as
// in 15.11, so a blueprint keeps the placeholder it had. Done here rather than
// in `Project#avatar_url` so it applies to the tiles alone: on the model it
// would reach every list, both APIs and the sidebar, and cost a custom-attribute
// query per project to scope it back.
const PLACEHOLDERS = [4, 1, 2, 3, 4, 5, 6, 1, 2, 3];

export const placeholderAvatarUrl = (id) =>
  `/-/oc/assets/images/uf-avatar-placeholder-${PLACEHOLDERS[id % PLACEHOLDERS.length]}.svg`;

const baseTab = {
  paginationType: PAGINATION_TYPE_KEYSET,
  listComponent: BlueprintsList,
  emptyStateComponent: ResourceListsEmptyState,
  emptyStateComponentProps: {
    svgPath: emptyStateProjectsSvgPath,
    searchMinimumLength: 3,
    type: TYPES.filter,
  },
  formatter: formatGraphQLProjects,
  queryErrorMessage: s__(
    'Blueprints|Blueprints could not be loaded. Refresh the page to try again.',
  ),
  sortOptions: SORT_OPTIONS,
  defaultSortOption: SORT_OPTION_CREATED,
  query: blueprintsQuery,
  queryPath: 'projects',
  variables: { unfurlType: 'BLUEPRINT' },
};

export const VERIFIED_TAB = {
  ...baseTab,
  text: s__('Blueprints|Verified'),
  value: 'verified',
  // Every blueprint here is ours, so the namespace is noise.
  listComponentProps: { showNamespace: false },
  // TabView spreads the filter variables over tab.variables, and an unset
  // namespace filter is `undefined`, which wins. transformVariables runs after
  // that spread.
  transformVariables: (variables) => ({ ...variables, namespacePath: VERIFIED_NAMESPACE_PATH }),
  emptyStateComponentProps: {
    ...baseTab.emptyStateComponentProps,
    title: s__('Blueprints|No verified blueprints found'),
    description: s__('Blueprints|Blueprints published by Unfurl Cloud appear here.'),
  },
};

export const STARRED_TAB = {
  ...baseTab,
  text: s__('Blueprints|Most stars'),
  value: 'starred',
  // Sorting by anything else would not be "most stars". Restricting the tab's
  // options is also what makes the default stick: TabsWithList prefers the
  // user's saved sort whenever it is one this tab offers.
  sortOptions: [SORT_OPTION_STARS],
  defaultSortOption: SORT_OPTION_STARS,
  emptyStateComponentProps: {
    ...baseTab.emptyStateComponentProps,
    title: s__('Blueprints|No blueprints found'),
    description: s__('Blueprints|Deploy an application from a blueprint, or publish your own.'),
  },
};

export const ALL_TAB = {
  ...baseTab,
  text: __('All'),
  value: 'all',
  emptyStateComponentProps: {
    ...baseTab.emptyStateComponentProps,
    title: s__('Blueprints|No blueprints found'),
    description: s__('Blueprints|Deploy an application from a blueprint, or publish your own.'),
  },
};

export const EXPLORE_BLUEPRINTS_TABS = [VERIFIED_TAB, STARRED_TAB, ALL_TAB];

// `/explore/blueprints` is the Verified tab, not a redirect to it.
export const FIRST_TAB_ROUTE_NAMES = ['root'];

export const FILTERED_SEARCH_NAMESPACE = 'blueprints';
export const FILTERED_SEARCH_TERM_KEY = 'name';
