<script>
import TabsWithList from '~/groups_projects/components/tabs_with_list.vue';
import {
  FILTERED_SEARCH_TOKEN_VISIBILITY_LEVEL,
  SORT_OPTION_CREATED,
  SORT_OPTION_UPDATED,
} from '~/groups_projects/constants';
import { RECENT_SEARCHES_STORAGE_KEY_PROJECTS } from '~/filtered_search/recent_searches_storage_keys';
import {
  TIMESTAMP_TYPE_CREATED_AT,
  TIMESTAMP_TYPE_LAST_ACTIVITY_AT,
} from '~/vue_shared/components/resource_lists/constants';
import {
  EXPLORE_BLUEPRINTS_TABS,
  FIRST_TAB_ROUTE_NAMES,
  FILTERED_SEARCH_NAMESPACE,
  FILTERED_SEARCH_TERM_KEY,
} from '../constants';

export default {
  EXPLORE_BLUEPRINTS_TABS,
  FIRST_TAB_ROUTE_NAMES,
  RECENT_SEARCHES_STORAGE_KEY_PROJECTS,
  FILTERED_SEARCH_TERM_KEY,
  FILTERED_SEARCH_NAMESPACE,
  filteredSearchSupportedTokens: [FILTERED_SEARCH_TOKEN_VISIBILITY_LEVEL],
  timestampTypeMap: {
    [SORT_OPTION_CREATED.value]: TIMESTAMP_TYPE_CREATED_AT,
    [SORT_OPTION_UPDATED.value]: TIMESTAMP_TYPE_LAST_ACTIVITY_AT,
  },
  name: 'ExploreBlueprintsApp',
  components: {
    TabsWithList,
  },
  props: {
    initialSort: {
      type: String,
      required: true,
    },
  },
};
</script>

<template>
  <tabs-with-list
    :tabs="$options.EXPLORE_BLUEPRINTS_TABS"
    :first-tab-route-names="$options.FIRST_TAB_ROUTE_NAMES"
    :filtered-search-supported-tokens="$options.filteredSearchSupportedTokens"
    :filtered-search-term-key="$options.FILTERED_SEARCH_TERM_KEY"
    :filtered-search-namespace="$options.FILTERED_SEARCH_NAMESPACE"
    :filtered-search-recent-searches-storage-key="$options.RECENT_SEARCHES_STORAGE_KEY_PROJECTS"
    :timestamp-type-map="$options.timestampTypeMap"
    :initial-sort="initialSort"
    user-preferences-sort-key="projectsSort"
  />
</template>
