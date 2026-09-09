import { ApolloLink } from '@apollo/client/core';
import { resolvers, link, typeDefs } from 'oc_vue_shared/graphql';
import createDefaultClient from '~/lib/graphql';

const client = createDefaultClient(resolvers, { typeDefs });
// oc-pages' link strips the fragments only its client-side resolvers use
// before a query reaches the server.
client.setLink(ApolloLink.concat(link, client.link));

export default client;
