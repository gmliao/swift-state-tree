<script setup lang="ts">
import { ref } from 'vue'
import { useRouter } from 'vue-router'

const router = useRouter()

// Room ID input (shared for all games)
// Default to 'default' room, or set to empty string to create new rooms
const roomId = ref<string>('default')

function goToCounter() {
  router.push({ 
    name: 'counter',
    query: roomId.value ? { roomId: roomId.value } : {}
  })
}

function goToCookie() {
  router.push({ 
    name: 'cookie-game',
    query: roomId.value ? { roomId: roomId.value } : {}
  })
}
</script>

<template>
  <div class="home-view">
    <!-- Hero Section -->
    <v-row justify="center" class="mb-3">
      <v-col cols="12" md="10" lg="8">
        <div class="text-center mb-4">
          <h1 class="text-h4 font-weight-bold mb-2">Welcome to SwiftStateTree</h1>
          <p class="text-subtitle-1 text-medium-emphasis">
            Explore real-time multiplayer demos powered by server-authoritative state synchronization
          </p>
        </div>

        <!-- Room Configuration Card -->
        <v-card variant="outlined" class="mb-4">
          <v-card-title class="d-flex align-center bg-surface-variant py-2">
            <v-icon icon="mdi-door" size="small" class="mr-2"></v-icon>
            <span class="text-subtitle-1">Room Configuration</span>
          </v-card-title>
          <v-card-text class="pa-4">
            <v-text-field
              v-model="roomId"
              label="Room ID (optional)"
              prepend-inner-icon="mdi-identifier"
              variant="outlined"
              density="compact"
              hint="Leave empty to create a new room, or enter an ID to join an existing room"
              persistent-hint
              clearable
              data-testid="room-id"
            ></v-text-field>
          </v-card-text>
        </v-card>
      </v-col>
    </v-row>

    <!-- Demo Cards -->
    <v-row justify="center">
      <v-col cols="12" md="10" lg="8">
        <v-row>
          <!-- Counter Demo Card -->
          <v-col cols="12" md="6">
            <v-card
              class="demo-card h-100"
              hover
              @click="goToCounter"
              data-testid="demo-counter"
            >
              <v-card-item class="pb-2">
                <template v-slot:prepend>
                  <v-avatar color="primary" size="48">
                    <v-icon icon="mdi-counter" size="28"></v-icon>
                  </v-avatar>
                </template>

                <v-card-title class="text-h6 mb-1">Counter Demo</v-card-title>
                <v-card-subtitle class="text-caption">Perfect for Getting Started</v-card-subtitle>
              </v-card-item>

              <v-card-text class="pt-2 pb-3">
                <p class="text-body-2 mb-3">
                  A shared counter that increments on click. Demonstrates real-time state synchronization.
                </p>
                
                <v-chip
                  color="success"
                  size="small"
                  prepend-icon="mdi-check-circle"
                  class="mr-2"
                >
                  Beginner Friendly
                </v-chip>
                <v-chip
                  color="info"
                  size="small"
                  prepend-icon="mdi-timer-sand"
                >
                  ~2 min
                </v-chip>
              </v-card-text>

              <v-card-actions class="px-4 pb-4 pt-0">
                <v-btn
                  color="primary"
                  variant="flat"
                  block
                  prepend-icon="mdi-play-circle"
                >
                  Launch Counter Demo
                </v-btn>
              </v-card-actions>
            </v-card>
          </v-col>

          <!-- Cookie Clicker Card -->
          <v-col cols="12" md="6">
            <v-card
              class="demo-card h-100"
              hover
              @click="goToCookie"
              data-testid="demo-cookie"
            >
              <v-card-item class="pb-2">
                <template v-slot:prepend>
                  <v-avatar color="warning" size="48">
                    <v-icon icon="mdi-cookie" size="28"></v-icon>
                  </v-avatar>
                </template>

                <v-card-title class="text-h6 mb-1">Cookie Clicker</v-card-title>
                <v-card-subtitle class="text-caption">Advanced Multiplayer Game</v-card-subtitle>
              </v-card-item>

              <v-card-text class="pt-2 pb-3">
                <p class="text-body-2 mb-3">
                  A full multiplayer game with upgrades, private state, tick-based logic, and leaderboards.
                </p>
                
                <v-chip
                  color="warning"
                  size="small"
                  prepend-icon="mdi-star"
                  class="mr-2"
                >
                  Advanced
                </v-chip>
                <v-chip
                  color="info"
                  size="small"
                  prepend-icon="mdi-account-multiple"
                >
                  Multiplayer
                </v-chip>
              </v-card-text>

              <v-card-actions class="px-4 pb-4 pt-0">
                <v-btn
                  color="warning"
                  variant="flat"
                  block
                  prepend-icon="mdi-play-circle"
                >
                  Launch Cookie Clicker
                </v-btn>
              </v-card-actions>
            </v-card>
          </v-col>
        </v-row>
      </v-col>
    </v-row>

    <!-- Features Overview (Product Dashboard Style) -->
    <v-row justify="center" class="mt-4">
      <v-col cols="12" md="10" lg="8">
        <v-card variant="outlined">
          <v-card-title class="bg-surface-variant py-2">
            <v-icon icon="mdi-feature-search" size="small" class="mr-2"></v-icon>
            <span class="text-subtitle-1">Key Features</span>
          </v-card-title>
          <v-card-text class="pa-4">
            <v-row dense>
              <v-col cols="6" sm="3">
                <div class="text-center">
                  <v-icon icon="mdi-sync" size="40" color="primary" class="mb-1"></v-icon>
                  <div class="text-body-2 font-weight-medium">Real-time Sync</div>
                  <div class="text-caption text-medium-emphasis">Instant updates</div>
                </div>
              </v-col>
              <v-col cols="6" sm="3">
                <div class="text-center">
                  <v-icon icon="mdi-shield-check" size="40" color="success" class="mb-1"></v-icon>
                  <div class="text-body-2 font-weight-medium">Server Authority</div>
                  <div class="text-caption text-medium-emphasis">Secure logic</div>
                </div>
              </v-col>
              <v-col cols="6" sm="3">
                <div class="text-center">
                  <v-icon icon="mdi-code-tags" size="40" color="info" class="mb-1"></v-icon>
                  <div class="text-body-2 font-weight-medium">Type-Safe</div>
                  <div class="text-caption text-medium-emphasis">Generated types</div>
                </div>
              </v-col>
              <v-col cols="6" sm="3">
                <div class="text-center">
                  <v-icon icon="mdi-lightning-bolt" size="40" color="warning" class="mb-1"></v-icon>
                  <div class="text-body-2 font-weight-medium">Fast Performance</div>
                  <div class="text-caption text-medium-emphasis">Optimized sync</div>
                </div>
              </v-col>
            </v-row>
          </v-card-text>
        </v-card>
      </v-col>
    </v-row>
  </div>
</template>

<style scoped>
.home-view {
  max-width: 100%;
}

.demo-card {
  cursor: pointer;
  transition: all 0.2s ease-in-out;
}

.demo-card:hover {
  transform: translateY(-4px);
}
</style>
