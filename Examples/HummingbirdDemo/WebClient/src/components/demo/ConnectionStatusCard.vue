<script setup lang="ts">
interface Props {
  connected: boolean
  joined: boolean
  roomId: string
  lastStateAt?: Date
  error?: string
}

defineProps<Props>()

const formatLastUpdate = (date?: Date) => {
  if (!date) return 'Never'
  const now = new Date()
  const diff = now.getTime() - date.getTime()
  if (diff < 1000) return 'Just now'
  if (diff < 60000) return `${Math.floor(diff / 1000)}s ago`
  if (diff < 3600000) return `${Math.floor(diff / 60000)}m ago`
  return date.toLocaleTimeString()
}
</script>

<template>
  <v-card variant="outlined" class="mb-4">
    <v-card-title class="bg-surface-variant py-2 d-flex align-center">
      <v-icon icon="mdi-lan-connect" size="small" class="mr-2" />
      <span class="text-subtitle-1">Connection Status</span>
    </v-card-title>
    
    <v-card-text class="pa-4">
      <v-row dense>
        <v-col cols="12" sm="6" md="3">
          <div class="text-caption text-medium-emphasis">Connection</div>
          <div class="d-flex align-center">
            <v-icon
              :icon="connected ? 'mdi-check-circle' : 'mdi-close-circle'"
              :color="connected ? 'success' : 'error'"
              size="small"
              class="mr-1"
            />
            <span class="text-body-2 font-weight-medium">
              {{ connected ? 'Connected' : 'Disconnected' }}
            </span>
          </div>
        </v-col>

        <v-col cols="12" sm="6" md="3">
          <div class="text-caption text-medium-emphasis">Room Status</div>
          <div class="d-flex align-center">
            <v-icon
              :icon="joined ? 'mdi-check-circle' : 'mdi-clock-outline'"
              :color="joined ? 'success' : 'warning'"
              size="small"
              class="mr-1"
            />
            <span class="text-body-2 font-weight-medium">
              {{ joined ? 'Joined' : 'Not Joined' }}
            </span>
          </div>
        </v-col>

        <v-col cols="12" sm="6" md="3">
          <div class="text-caption text-medium-emphasis">Room ID</div>
          <div class="text-body-2 font-weight-medium">{{ roomId }}</div>
        </v-col>

        <v-col cols="12" sm="6" md="3">
          <div class="text-caption text-medium-emphasis">Last State Update</div>
          <div class="text-body-2 font-weight-medium">{{ formatLastUpdate(lastStateAt) }}</div>
        </v-col>
      </v-row>

      <!-- Error Alert -->
      <v-alert
        v-if="error"
        type="error"
        variant="tonal"
        density="compact"
        class="mt-3"
      >
        {{ error }}
      </v-alert>
    </v-card-text>
  </v-card>
</template>
