import Vue from 'vue';
import VueApollo from 'vue-apollo';
import { ApolloLink } from '@apollo/client/core';
import { resolvers, link, typeDefs } from 'oc_vue_shared/graphql';
import createDefaultClient from '~/lib/graphql';

Vue.use(VueApollo);

const defaultClient = createDefaultClient(resolvers, { typeDefs });
// oc-pages' link strips the fragments only its client-side resolvers use
// before a query reaches the server.
defaultClient.setLink(ApolloLink.concat(link, defaultClient.link));

export default new VueApollo({ defaultClient });
