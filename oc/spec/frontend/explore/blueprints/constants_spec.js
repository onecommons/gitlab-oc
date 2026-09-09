import { VERIFIED_TAB, VERIFIED_NAMESPACE_PATH } from 'oc/explore/blueprints/constants';

describe('Explore blueprints tabs', () => {
  describe('Verified', () => {
    it('pins the namespace after the filter variables are merged in', () => {
      expect(
        VERIFIED_TAB.transformVariables({ namespacePath: undefined, sort: 'created_desc' }),
      ).toEqual({ namespacePath: VERIFIED_NAMESPACE_PATH, sort: 'created_desc' });
    });
  });
});
