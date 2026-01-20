<script setup lang="ts">
import { ref, onMounted, onUnmounted, watch } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import { useCounter } from '../generated/counter/useCounter'
import DemoLayout from '../components/demo/DemoLayout.vue'
import ConnectionStatusCard from '../components/demo/ConnectionStatusCard.vue'
import AuthorityHint from '../components/demo/AuthorityHint.vue'
import CounterStateInspector from '../components/demo/counter/CounterStateInspector.vue'

const router = useRouter()
const route = useRoute()

// Get room ID from query parameter
const roomId = (route.query.roomId as string) || 'default'

// Use generated composable
const {
  state,
  isJoined,
  connect,
  disconnect,
  increment
} = useCounter()

// Track connection state for UI
const connected = ref(false)
const lastStateAt = ref<Date>()
const error = ref<string>()

// Update lastStateAt when state changes
watch(state, () => {
  if (state.value) {
    lastStateAt.value = new Date()
  }
})

onMounted(async () => {
  try {
    await connect({
      wsUrl: 'ws://localhost:8080/game/counter',
      landID: roomId.trim() || undefined  // Pass room ID if provided
    })
    connected.value = true
    error.value = undefined
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Failed to connect'
    connected.value = false
  }
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
  <DemoLayout
    title="Counter Demo"
    :room-id="roomId"
    land-type="counter"
  >
    <!-- Connection Status -->
    <ConnectionStatusCard
      :connected="connected"
      :joined="isJoined"
      :room-id="roomId"
      :last-state-at="lastStateAt"
      :error="error"
    />

    <!-- Authority Hint -->
    <AuthorityHint />

    <v-row>
      <!-- Left: Actions -->
      <v-col cols="12" md="6">
        <v-card variant="outlined">
          <v-card-title class="bg-surface-variant py-2 d-flex align-center">
            <v-icon icon="mdi-gesture-tap" size="small" class="mr-2" />
            <span class="text-subtitle-1">Actions</span>
          </v-card-title>
          <v-card-text class="pa-4">
            <p class="text-body-2 text-medium-emphasis mb-4">
              Click the button below to send an <code>increment</code> action to the server.
              The server will process it and broadcast the updated count to all connected clients.
            </p>
            <v-btn
              color="primary"
              size="large"
              block
              :disabled="!isJoined"
              :loading="!connected"
              @click="handleIncrement"
              prepend-icon="mdi-plus-circle"
            >
              Increment Counter
            </v-btn>
          </v-card-text>
        </v-card>

        <!-- How It Works -->
        <v-card variant="outlined" class="mt-4">
          <v-card-title class="bg-surface-variant py-2 d-flex align-center">
            <v-icon icon="mdi-information" size="small" class="mr-2" />
            <span class="text-subtitle-1">How It Works</span>
          </v-card-title>
          <v-card-text class="pa-4">
            <p class="text-body-2 mb-3">
              This is the simplest SwiftStateTree example demonstrating real-time state synchronization.
            </p>
            <v-list density="compact" class="bg-transparent">
              <v-list-item prepend-icon="mdi-check-circle" title="Click the button to increment">
                <v-list-item-subtitle class="text-caption">The action is sent to the server</v-list-item-subtitle>
              </v-list-item>
              <v-list-item prepend-icon="mdi-sync" title="Server processes and broadcasts">
                <v-list-item-subtitle class="text-caption">All connected clients receive the update</v-list-item-subtitle>
              </v-list-item>
              <v-list-item prepend-icon="mdi-update" title="State updates instantly">
                <v-list-item-subtitle class="text-caption">No manual refresh needed</v-list-item-subtitle>
              </v-list-item>
            </v-list>
          </v-card-text>

          <v-divider />

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
      </v-col>

      <!-- Right: State Inspector -->
      <v-col cols="12" md="6">
        <CounterStateInspector
          :snapshot="state"
          :last-updated-at="lastStateAt"
        />
      </v-col>
    </v-row>
  </DemoLayout>
</template>

