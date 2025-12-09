<template>
  <v-card>
    <v-card-title>Logs</v-card-title>
    <v-card-text>
      <pre class="code">{{ store.logs.join("\n") }}</pre>
    </v-card-text>
  </v-card>
</template>

<script setup lang="ts">
import { useGameStore } from "../stores/game";
const store = useGameStore();
</script>

<style scoped>
.code {
  background: #1e1e1e;
  color: #dcdcdc;
  padding: 12px;
  border-radius: 8px;
  min-height: 160px;
  white-space: pre-wrap;
  font-family: ui-monospace, SFMono-Regular, Consolas, "Liberation Mono", Menlo, monospace;
}
</style>
