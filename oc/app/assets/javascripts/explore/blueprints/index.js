import Vue from 'vue';
import VueRouter from 'vue-router';
import VueApollo from 'vue-apollo';
import { initVueApp } from '~/lib/utils/vue3compat/init_vue_app';
import createDefaultClient from '~/lib/graphql';
import { convertObjectPropsToCamelCase } from '~/lib/utils/common_utils';
import ExploreBlueprintsApp from './components/app.vue';
import { EXPLORE_BLUEPRINTS_TABS } from './constants';

Vue.use(VueRouter);

export const createRouter = (basePath) =>
  new VueRouter({
    routes: [
      { name: 'root', path: '/', component: ExploreBlueprintsApp },
      ...EXPLORE_BLUEPRINTS_TABS.map(({ value }) => ({
        name: value,
        path: `/${value}`,
        component: ExploreBlueprintsApp,
      })),
    ],
    mode: 'history',
    base: basePath,
  });

export const initExploreBlueprints = () => {
  const el = document.getElementById('js-oc-explore-blueprints');

  if (!el) return null;

  const { basePath, initialSort } = convertObjectPropsToCamelCase(el.dataset);

  return initVueApp({
    el,
    router: createRouter(basePath),
    apolloProvider: new VueApollo({ defaultClient: createDefaultClient() }),
    name: 'ExploreBlueprintsRoot',
    component: ExploreBlueprintsApp,
    props: { initialSort },
  });
};
