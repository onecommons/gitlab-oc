import { SORT_OPTION_STARS } from '~/groups_projects/constants';
import {
  EXPLORE_BLUEPRINTS_TABS,
  FIRST_TAB_ROUTE_NAMES,
  STARRED_TAB,
  VERIFIED_TAB,
  VERIFIED_NAMESPACE_PATH,
} from 'oc/explore/blueprints/constants';

describe('Explore blueprints tabs', () => {
  it('offers the three tabs the fork has always had', () => {
    expect(EXPLORE_BLUEPRINTS_TABS.map(({ value, text }) => [value, text])).toEqual([
      ['verified', 'Verified'],
      ['starred', 'Most stars'],
      ['all', 'All'],
    ]);
  });

  it('filters every tab down to blueprints', () => {
    EXPLORE_BLUEPRINTS_TABS.forEach((tab) => {
      expect(tab.variables).toEqual({ unfurlType: 'BLUEPRINT' });
    });
  });

  it('treats the bare path as the first tab rather than redirecting to it', () => {
    expect(FIRST_TAB_ROUTE_NAMES).toEqual(['root']);
  });

  describe('Verified', () => {
    it('pins the namespace after the filter variables are merged in', () => {
      expect(
        VERIFIED_TAB.transformVariables({ namespacePath: undefined, sort: 'created_desc' }),
      ).toEqual({ namespacePath: VERIFIED_NAMESPACE_PATH, sort: 'created_desc' });
    });

    it('hides the namespace on tiles that all share one', () => {
      expect(VERIFIED_TAB.listComponentProps).toEqual({ showNamespace: false });
    });
  });

  describe('Most stars', () => {
    // A saved sort beats a tab's default whenever the tab offers it, so the
    // only way this tab stays sorted by stars is to offer nothing else.
    it('sorts by stars and offers no other order', () => {
      expect(STARRED_TAB.sortOptions).toEqual([SORT_OPTION_STARS]);
      expect(STARRED_TAB.defaultSortOption).toBe(SORT_OPTION_STARS);
    });
  });
});
