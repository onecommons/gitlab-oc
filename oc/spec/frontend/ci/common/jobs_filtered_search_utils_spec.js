import { validateQueryString } from '~/ci/common/private/jobs_filtered_search/utils';

// A deployment page links to the jobs page with ?var_deploy_path=<path>, and
// the value has to survive validation to reach the GraphQL query.
describe('validateQueryString with a deploy path', () => {
  it('passes the deploy path through as a GraphQL variable', () => {
    expect(validateQueryString({ var_deploy_path: 'production' })).toEqual({
      varDeployPath: 'production',
    });
  });

  it('keeps it alongside the filters upstream understands', () => {
    expect(validateQueryString({ var_deploy_path: 'production', statuses: 'success' })).toEqual({
      varDeployPath: 'production',
      statuses: 'SUCCESS',
    });
  });

  it('still drops a key nothing understands', () => {
    expect(validateQueryString({ nonsense: 'value' })).toBeNull();
  });
});
