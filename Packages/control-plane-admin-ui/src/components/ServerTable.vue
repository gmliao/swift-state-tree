<template>
  <v-card>
    <v-card-title>Registered Servers</v-card-title>
    <v-card-text>
      <p v-if="loading">Loading...</p>
      <v-data-table
        v-else
        :headers="headers"
        :items="servers"
        :items-length="servers.length"
        density="compact"
      >
        <template #item.hostPort="{ item }">
          {{ item.host }}:{{ item.port }}
        </template>
        <template #item.lastSeenAt="{ item }">
          {{ formatDate(item.lastSeenAt) }}
        </template>
        <template #item.isStale="{ item }">
          <v-chip :color="item.isStale ? 'error' : 'success'" size="small">
            {{ item.isStale ? 'Stale' : 'Alive' }}
          </v-chip>
        </template>
      </v-data-table>
    </v-card-text>
  </v-card>
</template>

<script setup lang="ts">
import type { ServerEntry } from '../api/adminApi'

defineProps<{
  servers: ServerEntry[]
  loading: boolean
}>()

const headers = [
  { title: 'Server ID', key: 'serverId' },
  { title: 'Land Type', key: 'landType' },
  { title: 'Host:Port', key: 'hostPort', sortable: false },
  { title: 'Last Seen', key: 'lastSeenAt' },
  { title: 'Status', key: 'isStale' },
]

function formatDate(iso: string): string {
  try {
    return new Date(iso).toLocaleString()
  } catch {
    return iso
  }
}
</script>
