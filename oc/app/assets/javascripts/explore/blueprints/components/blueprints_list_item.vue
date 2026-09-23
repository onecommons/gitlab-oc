<script>
import { GlButton, GlButtonGroup, GlIcon, GlLink } from '@gitlab/ui';
import { s__ } from '~/locale';
import TopicBadges from '~/vue_shared/components/topic_badges.vue';
import { projectStarrersPath } from '~/lib/utils/path_helpers/project';
import { placeholderAvatarUrl } from '../constants';

export default {
  name: 'BlueprintsListItem',
  i18n: {
    stars: s__('ProjectOverview|Stars'),
    starrers: s__('ProjectOverview|Starrers'),
    deploys: s__('ProjectOverview|Deploys'),
  },
  components: { GlButton, GlButtonGroup, GlIcon, GlLink, TopicBadges },
  props: {
    project: {
      type: Object,
      required: true,
    },
    showNamespace: {
      type: Boolean,
      required: false,
      default: true,
    },
  },
  emits: ['click-avatar', 'click-topic'],
  computed: {
    starrersHref() {
      return projectStarrersPath(this.project.fullPath);
    },
    deploymentsHref() {
      return `/${this.project.fullPath}`;
    },
    avatarUrl() {
      return this.project.avatarUrl || placeholderAvatarUrl(this.project.id);
    },
    namespaceName() {
      return this.project.namespace?.fullName;
    },
    hasTopics() {
      return Boolean(this.project.topics?.length);
    },
  },
};
</script>

<template>
  <li class="uf-tile">
    <div class="uf-tile-avatar">
      <a :href="project.relativeWebUrl" @click="$emit('click-avatar')">
        <img :src="avatarUrl" :alt="''" class="uf-tile-avatar-image" width="300" height="300" />
      </a>
    </div>

    <div class="uf-project-detail">
      <a
        :href="project.relativeWebUrl"
        :title="project.nameWithNamespace"
        :class="{ 'uf-explore-tight-header': showNamespace }"
        class="uf-no-link"
        @click="$emit('click-avatar')"
      >
        <h5 v-if="showNamespace && namespaceName" class="uf-truncate gl-m-0">
          {{ namespaceName }} /
        </h5>
        <h4 class="gl-my-2">{{ project.name }}</h4>
      </a>

      <div class="gl-flex gl-flex-wrap gl-items-center gl-justify-between gl-gap-3">
        <!-- 15.11 left the deploy count as a plain link, with only the stars
             pilled, so the two read as a count and a control. -->
        <gl-link
          :href="deploymentsHref"
          :title="$options.i18n.deploys"
          class="gl-inline-flex gl-items-center gl-gap-2"
        >
          <gl-icon name="rocket" />
          {{ project.blueprintDeploymentCount }} {{ $options.i18n.deploys }}
        </gl-link>

        <gl-button-group class="uf-badge-height">
          <gl-button :href="starrersHref" icon="star-o" size="small" class="uf-button">{{
            $options.i18n.stars
          }}</gl-button>
          <gl-button
            :href="starrersHref"
            :title="$options.i18n.starrers"
            size="small"
            class="uf-button"
            >{{ project.starCount }}</gl-button
          >
        </gl-button-group>
      </div>

      <p
        v-if="project.description"
        :title="project.description"
        class="uf-description uf-truncate gl-my-3"
        style="--line-clamp: 3"
      >
        {{ project.description }}
      </p>

      <topic-badges
        v-if="hasTopics"
        :topics="project.topics"
        :show-label="false"
        @click="$emit('click-topic')"
      />
    </div>
  </li>
</template>
