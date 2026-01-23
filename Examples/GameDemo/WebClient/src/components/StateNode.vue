<template>
  <div :style="{ marginLeft: level * 20 + 'px' }">
    <!-- Object/Array -->
    <div v-if="isObject" class="node-object">
      <span class="bracket">{{ isArray ? "[" : "{" }}</span>
      <div v-for="(value, key) in node" :key="key" class="node-child">
        <span class="key">{{ key }}:</span>
        <StateNode
          :node="value"
          :path="[...path, String(key)]"
          :level="level + 1"
        />
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
.node-child {
  padding-left: 20px;
  border-left: 1px solid rgba(0, 0, 0, 0.05);
}

.key {
  color: var(--color-secondary);
  font-weight: 600;
  margin-right: 8px;
  font-size: 13px;
}

.bracket {
  color: var(--color-text-muted);
  font-weight: 400;
  opacity: 0.6;
}

.node-value {
  display: inline-flex;
  align-items: center;
  background: rgba(0, 0, 0, 0.02);
  padding: 1px 6px;
  border-radius: 4px;
}

.value-match {
  color: var(--color-success);
  font-weight: 500;
}

.value-mismatch {
  color: var(--color-error);
  font-weight: 700;
  text-decoration: line-through;
  opacity: 0.7;
}

.expected-value {
  margin-left: 8px;
  color: var(--color-success);
  font-weight: 700;
  background: var(--color-primary-soft);
  padding: 1px 6px;
  border-radius: 4px;
}

.node-object {
  margin: 2px 0;
}
</style>
