import { GlAlert, GlLink } from '@gitlab/ui';
import Vue from 'vue';
import VueApollo from 'vue-apollo';
import createMockApollo from 'helpers/mock_apollo_helper';
import waitForPromises from 'helpers/wait_for_promises';
import { shallowMountExtended } from 'helpers/vue_test_utils_helper';
import * as Sentry from '~/sentry/sentry_browser_wrapper';
import ReplicaBanner from 'oc/work_items/components/replica_banner.vue';
import replicaQuery from 'oc/work_items/graphql/replica.query.graphql';

Vue.use(VueApollo);

describe('OcReplicaBanner', () => {
  let wrapper;

  const workItemId = 'gid://gitlab/WorkItem/1';

  const response = (ocReplica) => ({
    data: {
      workItem: { __typename: 'WorkItem', id: workItemId, ocReplica },
    },
  });

  const createComponent = (handler) => {
    wrapper = shallowMountExtended(ReplicaBanner, {
      apolloProvider: createMockApollo([[replicaQuery, handler]]),
      propsData: { workItemId },
      stubs: { GlAlert },
    });

    return waitForPromises();
  };

  const findAlert = () => wrapper.findComponent(GlAlert);
  const findLink = () => wrapper.findComponent(GlLink);

  it('renders nothing for an ordinary work item', async () => {
    await createComponent(jest.fn().mockResolvedValue(response(null)));

    expect(findAlert().exists()).toBe(false);
  });

  it('says the item is a copy and links to the original', async () => {
    await createComponent(
      jest.fn().mockResolvedValue(
        response({
          __typename: 'OCWorkItemReplica',
          surrendered: false,
          sourceWebUrl: 'https://peer.example.com/group/project/-/issues/42',
        }),
      ),
    );

    expect(findAlert().text()).toContain(
      'Read-only copy of an item on another Unfurl Cloud instance.',
    );
    expect(findLink().attributes('href')).toBe(
      'https://peer.example.com/group/project/-/issues/42',
    );
    expect(findLink().text()).toBe('View the original');
  });

  it('uses its own words for an item being transferred away, which has no original yet', async () => {
    await createComponent(
      jest
        .fn()
        .mockResolvedValue(
          response({ __typename: 'OCWorkItemReplica', surrendered: true, sourceWebUrl: null }),
        ),
    );

    expect(findAlert().text()).toBe(
      'Being transferred to another Unfurl Cloud instance, and read-only until it arrives there.',
    );
    expect(findLink().exists()).toBe(false);
  });

  it('cannot be dismissed, because the item stays read-only', async () => {
    await createComponent(
      jest
        .fn()
        .mockResolvedValue(
          response({ __typename: 'OCWorkItemReplica', surrendered: false, sourceWebUrl: null }),
        ),
    );

    expect(findAlert().props('dismissible')).toBe(false);
    expect(findLink().exists()).toBe(false);
  });

  it('shows nothing and reports the error when the query fails', async () => {
    jest.spyOn(Sentry, 'captureException').mockImplementation();

    await createComponent(jest.fn().mockRejectedValue(new Error('boom')));

    expect(findAlert().exists()).toBe(false);
    expect(Sentry.captureException).toHaveBeenCalled();
  });
});
