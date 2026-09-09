<script>
import { GlButton } from '@gitlab/ui';

export default {
  name: 'EditionTopbarLinks',
  components: { GlButton },
  props: {
    links: {
      type: Array,
      required: false,
      default: () => [],
    },
  },
};
</script>

<template>
  <nav v-if="links.length" class="uf-topbar-nav gl-hidden gl-items-stretch sm:gl-flex">
    <gl-button
      v-for="link in links"
      :key="link.href"
      :href="link.href"
      :icon="link.icon"
      :title="link.text"
      :class="{ 'uf-topbar-link-current': link.active }"
      :aria-current="link.active ? 'page' : null"
      category="tertiary"
      class="uf-topbar-link"
      >{{ link.text }}</gl-button
    >
  </nav>
</template>
