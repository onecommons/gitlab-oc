<script lang="ts">
import { typed } from './typed';

export default {
  name: 'TsWidget',
  data() {
    return { msg: typed };
  },
};
</script>

<template>
  <div>{{ msg }}</div>
</template>
