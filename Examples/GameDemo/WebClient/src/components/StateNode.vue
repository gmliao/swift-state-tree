<template>
  <div :style="{ marginLeft: level * 20 + 'px' }">
    <!-- Object/Array -->
    <div v-if="isObject" class="node-object">
      <span class="bracket">{{ isArray ? "[" : "{" }}</span>
      <div v-for="(value, key) in node" :key="key" class="node-child">
        <span class="key">{{ key }}:</span>
        <StateNode :node="value" :path="[...path, key]" :level="level + 1" />
      </div>
      <span class="bracket">{{ isArray ? "]" : "}" }}</span>
    </div>

    <!-- Primitive value -->
    <div v-else class="node-value">
      <span
        :class="{
          'value-match': node.isMatch,
          'value-mismatch': !node.isMatch,
        }"
      >
        {{ formatValue(node.value) }}
      </span>

      <!-- Show expected value if mismatch -->
      <span v-if="!node.isMatch" class="expected-value">
        ← 預期: {{ formatValue(node.expected) }}
      </span>

      <v-icon
        :color="node.isMatch ? 'success' : 'error'"
        size="small"
        class="ml-1"
      >
        {{ node.isMatch ? "mdi-check" : "mdi-alert-circle" }}
      </v-icon>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed } from "vue";

const props = defineProps<{
  node: any;
  path: string[];
  level: number;
}>();

const isObject = computed(() => {
  return !props.node.hasOwnProperty("value");
});

const isArray = computed(() => {
  return Array.isArray(props.node);
});

function formatValue(value: any): string {
  if (typeof value === "string") return `"${value}"`;
  if (value === null) return "null";
  if (value === undefined) return "undefined";
  return String(value);
}
</script>

<style scoped>
.node-object {
  display: flex;
  flex-direction: column;
}

.node-child {
  display: flex;
  align-items: baseline;
  gap: 8px;
}

.key {
  color: #0066cc;
  font-weight: 500;
}

.bracket {
  color: #666;
}

.node-value {
  display: inline-flex;
  align-items: center;
  gap: 4px;
}

.value-match {
  color: #2e7d32;
}

.value-mismatch {
  color: #c62828;
  font-weight: bold;
}

.expected-value {
  color: #666;
  font-size: 12px;
  font-style: italic;
}
</style>
