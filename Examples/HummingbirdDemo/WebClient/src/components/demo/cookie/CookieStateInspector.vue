<script setup lang="ts">
import { computed } from 'vue'
import MetricGrid from '../MetricGrid.vue'
import type { CookieSnapshot } from '../../../generated/cookie'

interface Props {
  snapshot: CookieSnapshot | null
  lastUpdatedAt?: Date
}

const props = defineProps<Props>()

const metrics = computed(() => {
  if (!props.snapshot) return []
  
  const playerState = props.snapshot.players[0] // Assume first player for now
  
  return [
    {
      label: 'Total Cookies',
      value: playerState?.cookies.toFixed(1) ?? 0,
      icon: 'mdi-cookie',
      color: 'warning'
    },
    {
      label: 'Cookies/sec',
      value: playerState?.cookiesPerSecond.toFixed(1) ?? 0,
      icon: 'mdi-speedometer',
      color: 'success'
    },
    {
      label: 'Upgrades Owned',
      value: playerState?.upgrades.length ?? 0,
      icon: 'mdi-star',
      color: 'info'
    },
    {
      label: 'Last Update',
      value: props.lastUpdatedAt 
        ? `${new Date().getTime() - props.lastUpdatedAt.getTime()}ms ago`
        : 'Never',
      icon: 'mdi-clock-outline',
      color: 'primary'
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
