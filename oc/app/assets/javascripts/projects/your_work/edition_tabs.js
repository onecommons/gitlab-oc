import emptyStateProjectsSvgPath from '@gitlab/svgs/dist/illustrations/empty-state/empty-projects-md.svg?url';
import { s__ } from '~/locale';
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
import { ACCESS_LEVEL_MAINTAINER_STRING } from '~/access_level/constants';
import projectsQuery from './graphql/queries/projects.query.graphql';

// constants.js imports this file, so the shared shape cannot come from there.
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
    "Projects|Your projects couldn't be loaded. Refresh the page to try again.",
  ),
  sortOptions: SORT_OPTIONS,
  defaultSortOption: SORT_OPTION_CREATED,
  query: projectsQuery,
  queryPath: 'projects',
};

export const DASHBOARDS_TAB = {
  ...baseTab,
  text: s__('YourWork|Dashboards'),
  value: 'dashboards',
  variables: { unfurlType: 'DASHBOARD', minAccessLevel: ACCESS_LEVEL_MAINTAINER_STRING },
  emptyStateComponentProps: {
    ...baseTab.emptyStateComponentProps,
    title: s__('YourWork|You do not maintain any dashboards yet.'),
  },
};

export const BLUEPRINTS_TAB = {
  ...baseTab,
  text: s__('YourWork|Blueprints'),
  value: 'blueprints',
  variables: { unfurlType: 'BLUEPRINT', membership: true },
  emptyStateComponentProps: {
    ...baseTab.emptyStateComponentProps,
    title: s__('YourWork|You are not a member of any blueprints yet.'),
  },
};

export default [DASHBOARDS_TAB, BLUEPRINTS_TAB];
