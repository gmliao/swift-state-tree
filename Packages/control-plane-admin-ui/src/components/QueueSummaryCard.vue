<template>
  <v-card>
    <v-card-title>Queue Summary</v-card-title>
    <v-card-text>
      <p v-if="admin.loading">Loading...</p>
      <template v-else-if="admin.queueSummary">
        <p v-if="admin.queueSummary.queueKeys.length === 0">No queued tickets</p>
        <v-list v-else density="compact">
          <v-list-item
            v-for="k in admin.queueSummary.queueKeys"
            :key="k"
            :title="k"
            :subtitle="`${admin.queueSummary!.byQueueKey[k]?.queuedCount ?? 0} queued`"
          />
        </v-list>
      </template>
      <p v-else>No data</p>
    </v-card-text>
  </v-card>
</template>

<script setup lang="ts">
import { useAdminStore } from '../stores/admin'

const admin = useAdminStore()
</script>
