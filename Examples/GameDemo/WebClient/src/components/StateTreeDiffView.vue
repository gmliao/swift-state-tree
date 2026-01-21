<template>
  <v-card>
    <v-card-title>
      Tick #{{ tickId }} 狀態
      <v-chip :color="isMatch ? 'success' : 'error'" class="ml-2" size="small">
        {{ isMatch ? "✅ 匹配" : "❌ 不匹配" }}
      </v-chip>
    </v-card-title>
    <v-card-text>
      <div class="state-tree">
        <StateNode :node="mergedState" :path="[]" :level="0" />
      </div>
    </v-card-text>
  </v-card>
</template>

<script setup lang="ts">
import { computed } from "vue";
import StateNode from "./StateNode.vue";

const props = defineProps<{
  tickId: number;
  expectedState: any;
  actualState: any;
  isMatch: boolean;
}>();

// Merge two states and mark differences
const mergedState = computed(() => {
  return mergeStates(props.expectedState, props.actualState);
});

function mergeStates(expected: any, actual: any): any {
  if (typeof expected !== "object" || expected === null) {
    return {
      value: actual,
      expected: expected,
      isMatch: JSON.stringify(expected) === JSON.stringify(actual),
      type: typeof actual,
    };
  }

  const merged: any = {};
  const allKeys = new Set([
    ...Object.keys(expected || {}),
    ...Object.keys(actual || {}),
  ]);

  for (const key of allKeys) {
    const exp = expected?.[key];
    const act = actual?.[key];

    if (typeof exp === "object" && exp !== null) {
      merged[key] = mergeStates(exp, act);
    } else {
      merged[key] = {
        value: act,
        expected: exp,
        isMatch: JSON.stringify(exp) === JSON.stringify(act),
        type: typeof act,
      };
    }
  }

  return merged;
}
</script>

<style scoped>
.state-tree {
  font-family: "Monaco", "Menlo", monospace;
  font-size: 14px;
}
</style>
