<script>
import BlueprintsListItem from './blueprints_list_item.vue';

export default {
  name: 'BlueprintsList',
  components: { BlueprintsListItem },
  // TabView passes the list every prop a list component might want, including
  // ones this grid has no use for.
  inheritAttrs: false,
  props: {
    items: {
      type: Array,
      required: true,
    },
    showNamespace: {
      type: Boolean,
      required: false,
      default: true,
    },
  },
  emits: ['click-avatar', 'click-topic'],
};
</script>

<template>
  <ul class="project-oc-container">
    <blueprints-list-item
      v-for="project in items"
      :key="project.id"
      :project="project"
      :show-namespace="showNamespace"
      @click-avatar="$emit('click-avatar')"
      @click-topic="$emit('click-topic')"
    />
  </ul>
</template>
