<script setup lang="ts">
import { onMounted, onUnmounted } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import { useCounter } from '../generated/counter/useCounter'

const router = useRouter()
const route = useRoute()

// Get room ID from query parameter
const roomId = (route.query.roomId as string) || ''

// Use generated composable
const {
  state,
  isJoined,
  connect,
  disconnect,
  increment
} = useCounter()

onMounted(async () => {
  await connect({
    wsUrl: 'ws://localhost:8080/game/counter',
    landID: roomId.trim() || undefined  // Pass room ID if provided
  })
})

onUnmounted(async () => {
  await disconnect()
})

async function handleIncrement() {
  await increment({})
}

async function handleLeave() {
  await disconnect()
  router.push({ name: 'home' })
}
</script>

<template>
  <v-container class="counter-page">
    <v-row justify="center">
      <v-col cols="12" md="8" lg="6">
        <!-- Loading State -->
        <v-card v-if="!isJoined || !state" variant="outlined" class="text-center pa-8">
          <v-progress-circular
            indeterminate
            color="primary"
            size="64"
            class="mb-4"
          ></v-progress-circular>
          <v-card-title>Connecting to Server...</v-card-title>
          <v-card-subtitle>Please wait while we establish connection</v-card-subtitle>
        </v-card>

        <!-- Connected State -->
        <div v-else>
          <!-- Counter Display Card -->
          <v-card variant="outlined" class="mb-6">
            <v-card-item>
              <template v-slot:prepend>
                <v-avatar color="primary" size="48">
                  <v-icon icon="mdi-counter" size="32"></v-icon>
                </v-avatar>
              </template>
              <v-card-title class="text-h5">Counter Demo</v-card-title>
              <v-card-subtitle>Real-time Synchronized Counter</v-card-subtitle>
            </v-card-item>

            <v-divider></v-divider>

            <v-card-text class="pa-8 text-center">
              <div class="text-h6 text-medium-emphasis mb-2">Current Count</div>
              <div class="text-h2 font-weight-bold text-primary mb-6">
                {{ state.count ?? 0 }}
              </div>

              <v-btn
                color="primary"
                size="x-large"
                variant="flat"
                @click="handleIncrement"
                prepend-icon="mdi-plus-circle"
                block
              >
                Increment Counter
              </v-btn>
            </v-card-text>
          </v-card>

          <!-- Info Card -->
          <v-card variant="outlined">
            <v-card-title class="bg-surface-variant">
              <v-icon icon="mdi-information" class="mr-2"></v-icon>
              How It Works
            </v-card-title>
            <v-card-text class="pa-6">
              <p class="text-body-1 mb-3">
                This is the simplest SwiftStateTree example demonstrating real-time state synchronization.
              </p>
              <v-list density="compact" class="bg-transparent">
                <v-list-item prepend-icon="mdi-check-circle" title="Click the button to increment">
                  <v-list-item-subtitle>The action is sent to the server</v-list-item-subtitle>
                </v-list-item>
                <v-list-item prepend-icon="mdi-sync" title="Server processes and broadcasts">
                  <v-list-item-subtitle>All connected clients receive the update</v-list-item-subtitle>
                </v-list-item>
                <v-list-item prepend-icon="mdi-update" title="State updates instantly">
                  <v-list-item-subtitle>No manual refresh needed</v-list-item-subtitle>
                </v-list-item>
              </v-list>
            </v-card-text>

            <v-divider></v-divider>

            <v-card-actions class="pa-4">
              <v-btn
                color="grey-darken-1"
                variant="tonal"
                prepend-icon="mdi-arrow-left"
                @click="handleLeave"
                block
              >
                Leave Demo
              </v-btn>
            </v-card-actions>
          </v-card>
        </div>
      </v-col>
    </v-row>
  </v-container>
</template>

<style scoped>
.counter-page {
  max-width: 100%;
  padding-top: 24px;
}
</style>
