<script setup lang="ts">
import { computed } from 'vue'
import MetricGrid from '../MetricGrid.vue'
import type { CounterSnapshot } from '../../../generated/counter'
import { formatSince } from '../../../utils/time'
import { useNow } from '../../../utils/useNow'

interface Props {
  snapshot: CounterSnapshot | null
  lastUpdatedAt?: Date
}

const props = defineProps<Props>()

const { nowMs } = useNow(1000)

const metrics = computed(() => {
  if (!props.snapshot) return []
  
  return [
    {
      label: 'Count',
      value: props.snapshot.count,
      icon: 'mdi-counter',
      color: 'primary'
    },
    {
      label: 'Updated',
      value: formatSince(props.lastUpdatedAt, nowMs.value),
      icon: 'mdi-clock-outline',
      color: 'info'
    }
  ]
})
</script>

<template>
  <v-card variant="outlined">
    <v-card-title class="bg-surface-variant py-2 d-flex align-center">
      <v-icon icon="mdi-state-machine" size="small" class="mr-2" />
      <span class="text-subtitle-1">State Inspector</span>
      <v-spacer />
      <v-chip size="x-small" color="success" variant="flat">
        Synced from Server
      </v-chip>
    </v-card-title>

    <v-card-text class="pa-4">
      <v-alert
        v-if="!snapshot"
        type="info"
        variant="tonal"
        density="compact"
      >
        No state received yet. Join a room to start.
      </v-alert>

      <MetricGrid v-else :metrics="metrics" :columns="2" />
    </v-card-text>

    <!-- Advanced: Full Snapshot JSON (collapsed by default) -->
    <v-expansion-panels v-if="snapshot" variant="accordion" class="ma-4 mt-0">
      <v-expansion-panel>
        <v-expansion-panel-title>
          <span class="text-caption">Advanced: Full Snapshot JSON</span>
        </v-expansion-panel-title>
        <v-expansion-panel-text>
          <pre class="text-caption pa-2 bg-surface-variant rounded">{{ JSON.stringify(snapshot, null, 2) }}</pre>
        </v-expansion-panel-text>
      </v-expansion-panel>
    </v-expansion-panels>
  </v-card>
</template>
