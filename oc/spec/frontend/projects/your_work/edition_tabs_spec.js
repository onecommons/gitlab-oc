import EDITION_TABS from 'oc_else_ce/projects/your_work/edition_tabs';
import { PROJECT_DASHBOARD_TABS } from '~/projects/your_work/constants';

describe('Your Work edition tabs', () => {
  it('filters by Unfurl classification', () => {
    expect(EDITION_TABS.map(({ value, variables }) => [value, variables])).toEqual([
      ['dashboards', { unfurlType: 'DASHBOARD', minAccessLevel: 'MAINTAINER' }],
      ['blueprints', { unfurlType: 'BLUEPRINT', membership: true }],
    ]);
  });

  it('appends them after the upstream tabs', () => {
    expect(PROJECT_DASHBOARD_TABS.map(({ value }) => value)).toEqual([
      'contributed',
      'starred',
      'personal',
      'member',
      'inactive',
      'dashboards',
      'blueprints',
    ]);
  });
});
