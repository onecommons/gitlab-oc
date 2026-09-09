import emptyStateProjectsSvgPath from '@gitlab/svgs/dist/illustrations/empty-state/empty-projects-md.svg?url';
import { __, s__ } from '~/locale';
import ProjectsList from '~/vue_shared/components/projects_list/projects_list.vue';
import ResourceListsEmptyState, {
  TYPES,
} from '~/vue_shared/components/resource_lists/empty_state.vue';
import { formatGraphQLProjects } from '~/vue_shared/components/projects_list/formatter';
import {
  PAGINATION_TYPE_KEYSET,
  SORT_OPTIONS,
  SORT_OPTION_CREATED,
} from '~/groups_projects/constants';
import blueprintsQuery from './graphql/queries/blueprints.query.graphql';

// The group that holds the blueprints Unfurl Cloud publishes itself.
export const VERIFIED_NAMESPACE_PATH = 'onecommons/blueprints';

const baseTab = {
  paginationType: PAGINATION_TYPE_KEYSET,
  listComponent: ProjectsList,
  listComponentProps: {
    listItemClass: 'gl-px-5',
    showProjectIcon: true,
  },
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
};

export const VERIFIED_TAB = {
  ...baseTab,
  text: s__('Blueprints|Verified'),
  value: 'verified',
  variables: { unfurlType: 'BLUEPRINT', namespacePath: VERIFIED_NAMESPACE_PATH },
  emptyStateComponentProps: {
    ...baseTab.emptyStateComponentProps,
    title: s__('Blueprints|No verified blueprints found'),
    description: s__('Blueprints|Blueprints published by Unfurl Cloud appear here.'),
  },
};

export const ALL_TAB = {
  ...baseTab,
  text: __('All'),
  value: 'all',
  variables: { unfurlType: 'BLUEPRINT' },
  emptyStateComponentProps: {
    ...baseTab.emptyStateComponentProps,
    title: s__('Blueprints|No blueprints found'),
    description: s__('Blueprints|Deploy an application from a blueprint, or publish your own.'),
  },
};

export const EXPLORE_BLUEPRINTS_TABS = [VERIFIED_TAB, ALL_TAB];

export const FILTERED_SEARCH_NAMESPACE = 'blueprints';
export const FILTERED_SEARCH_TERM_KEY = 'name';
