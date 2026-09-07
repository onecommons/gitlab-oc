<script>
import { GlAlert, GlLink } from '@gitlab/ui';
import * as Sentry from '~/sentry/sentry_browser_wrapper';
import { s__ } from '~/locale';
import replicaQuery from '../graphql/replica.query.graphql';

// Why a read-only work item is read-only. The policy prevents every write on
// a replica; without this the page only shows an item that cannot be edited.
//
// A query of its own rather than a field on the shared WorkItem fragment:
// lists never need it, and every mock of that fragment would otherwise have
// to carry it.
export default {
  name: 'OcReplicaBanner',
  i18n: {
    imported: s__('WorkItem|Read-only copy of an item on another Unfurl Cloud instance.'),
    viewOriginal: s__('WorkItem|View the original'),
    // Its own words: the item is ours, being given away, and has no original
    // to link to until the receiving instance publishes its copy.
    surrendered: s__(
      'WorkItem|Being transferred to another Unfurl Cloud instance, and read-only until it arrives there.',
    ),
  },
  components: {
    GlAlert,
    GlLink,
  },
  props: {
    workItemId: {
      type: String,
      required: true,
    },
  },
  data() {
    return {
      replica: null,
    };
  },
  apollo: {
    replica: {
      query: replicaQuery,
      variables() {
        return { id: this.workItemId };
      },
      update(data) {
        return data?.workItem?.ocReplica ?? null;
      },
      error(error) {
        Sentry.captureException(error);
      },
    },
  },
};
</script>

<template>
  <gl-alert
    v-if="replica"
    variant="info"
    :dismissible="false"
    class="gl-mb-5"
    data-testid="oc-replica-banner"
  >
    <template v-if="replica.surrendered">{{ $options.i18n.surrendered }}</template>
    <template v-else>
      {{ $options.i18n.imported }}
      <gl-link
        v-if="replica.sourceWebUrl"
        :href="replica.sourceWebUrl"
        target="_blank"
        data-testid="oc-replica-original-link"
        >{{ $options.i18n.viewOriginal }}</gl-link
      >
    </template>
  </gl-alert>
</template>
