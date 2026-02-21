<template>
  <v-container>
    <h1 class="text-h4 mb-4">Dashboard</h1>
    <v-alert v-if="admin.error" type="error" class="mb-4">{{ admin.error }}</v-alert>
    <v-row>
      <v-col cols="12" md="6">
        <QueueSummaryCard />
      </v-col>
      <v-col cols="12" md="6">
        <v-card>
          <v-card-title>Servers</v-card-title>
          <v-card-text>
            <p v-if="admin.loading">Loading...</p>
            <p v-else>{{ admin.servers.length }} server(s) registered</p>
            <v-btn to="/servers" variant="outlined" class="mt-2">View all</v-btn>
          </v-card-text>
        </v-card>
      </v-col>
    </v-row>
  </v-container>
</template>

<script setup lang="ts">
import { onMounted } from 'vue'
import { useAdminStore } from '../stores/admin'
import QueueSummaryCard from '../components/QueueSummaryCard.vue'

const admin = useAdminStore()

onMounted(() => {
  admin.fetchAll()
})
</script>
