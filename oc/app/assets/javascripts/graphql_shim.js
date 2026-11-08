import { ApolloLink } from '@apollo/client/core';
import { link } from 'oc_vue_shared/graphql';
import createDefaultClient from '~/lib/graphql';

const client = createDefaultClient();
// oc-pages' link strips fragment definitions a query does not use before it
// reaches the server, which would reject them.
client.setLink(ApolloLink.concat(link, client.link));

export default client;
