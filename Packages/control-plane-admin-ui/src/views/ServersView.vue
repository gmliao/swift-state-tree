<template>
  <v-container>
    <h1 class="text-h4 mb-4">Servers</h1>
    <v-alert v-if="admin.error" type="error" class="mb-4">{{ admin.error }}</v-alert>
    <ServerTable :servers="admin.servers" :loading="admin.loading" />
  </v-container>
</template>

<script setup lang="ts">
import { onMounted } from 'vue'
import { useAdminStore } from '../stores/admin'
import ServerTable from '../components/ServerTable.vue'

const admin = useAdminStore()

onMounted(() => {
  admin.fetchServers()
})
</script>
