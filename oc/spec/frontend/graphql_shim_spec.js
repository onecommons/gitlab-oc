import client from 'oc/graphql_shim';

describe('OC GraphQL shim', () => {
  // oc-pages calls graphqlClient.query directly, so the shim exports the
  // client itself. It exported a VueApollo provider until 19.3, and the
  // mismatch went unnoticed until every oc-pages query threw.
  it('resolves the oc alias and exports an Apollo client', () => {
    expect(client.query).toEqual(expect.any(Function));
    expect(client.mutate).toEqual(expect.any(Function));
  });

  it('is the client rather than a Vue Apollo provider', () => {
    expect(client.defaultClient).toBeUndefined();
  });
});
