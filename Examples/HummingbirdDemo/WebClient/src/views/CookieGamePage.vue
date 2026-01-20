<script setup lang="ts">
import { computed, ref, onMounted, onUnmounted } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import { useCookie } from '../generated/cookie/useCookie'
import {
  filterOtherPlayers,
  getCurrentPlayer,
  getCurrentPlayerPrivateState,
  getUpgradeLevel,
  calculateUpgradeCost
} from '../utils/gameLogic'

const router = useRouter()
const route = useRoute()

// Room ID from query parameter
const roomId = ref<string>((route.query.roomId as string) || '')

const {
  state,
  currentPlayerID,
  isJoined,
  isConnecting,
  connect,
  disconnect,
  clickCookie,
  buyUpgrade
} = useCookie()

onMounted(async () => {
  // Auto-connect with room ID from query parameter
  await handleConnect()
})

onUnmounted(async () => {
  await disconnect()
})

async function handleConnect() {
  if (isConnecting.value || isJoined.value) return
  
  try {
    await connect({
      wsUrl: 'ws://localhost:8080/game/cookie',
      landID: roomId.value.trim() || undefined  // Pass room ID from query parameter
    })
  } catch (error) {
    console.error('Failed to connect:', error)
  }
}

// Use extracted logic functions for better testability
const me = computed(() => getCurrentPlayer(state.value, currentPlayerID.value))
const myPrivate = computed(() => getCurrentPlayerPrivateState(state.value, currentPlayerID.value))
const others = computed(() => filterOtherPlayers(state.value?.players ?? {}, currentPlayerID.value))

async function handleClick() {
  await clickCookie({ amount: 1 })
}

async function handleBuy(upgradeID: string) {
  await buyUpgrade({ upgradeID })
}

async function handleLeave() {
  await disconnect()
  router.push({ name: 'home' })
}

// Use extracted logic functions
const cursorLevel = computed(() => getUpgradeLevel(myPrivate.value, 'cursor'))
const grandmaLevel = computed(() => getUpgradeLevel(myPrivate.value, 'grandma'))

// Calculate upgrade costs using extracted logic
const cursorCost = computed(() => calculateUpgradeCost(cursorLevel.value, 10))
const grandmaCost = computed(() => calculateUpgradeCost(grandmaLevel.value, 50))

// Helper: Can afford upgrade?
const canAffordCursor = computed(() => (me.value?.cookies ?? 0) >= cursorCost.value)
const canAffordGrandma = computed(() => (me.value?.cookies ?? 0) >= grandmaCost.value)
</script>

<template>
  <v-container fluid class="cookie-game-page">
    <!-- Loading State -->
    <v-row v-if="isConnecting" justify="center">
      <v-col cols="12" md="8">
        <v-card variant="outlined" class="text-center pa-8">
          <v-progress-circular
            indeterminate
            color="warning"
            size="64"
            class="mb-4"
          ></v-progress-circular>
          <v-card-title>Connecting to Cookie Room...</v-card-title>
          <v-card-subtitle>Preparing your bakery</v-card-subtitle>
        </v-card>
      </v-col>
    </v-row>

    <!-- Not Connected State -->
    <v-row v-if="!isJoined || !state" v-show="!isConnecting" justify="center">
      <v-col cols="12" md="6">
        <v-alert
          type="warning"
          variant="tonal"
          prominent
          class="mb-4"
        >
          <v-alert-title>Not Connected</v-alert-title>
          Unable to connect to the cookie server. Please return to home and try again.
        </v-alert>
        <v-btn
          color="primary"
          variant="flat"
          prepend-icon="mdi-home"
          block
          @click="handleLeave"
        >
          Return to Home
        </v-btn>
      </v-col>
    </v-row>

    <!-- Game UI -->
    <div v-else>
      <v-row>
        <!-- Left Column: Player Actions -->
        <v-col cols="12" lg="6">
          <!-- Player Stats Card -->
          <v-card variant="outlined" class="mb-4" v-if="me">
            <v-card-item>
              <template v-slot:prepend>
                <v-avatar color="warning" size="48">
                  <v-icon icon="mdi-account" size="32"></v-icon>
                </v-avatar>
              </template>
              <v-card-title class="text-h6">{{ me.name || 'You' }}</v-card-title>
              <v-card-subtitle>Your Bakery Stats</v-card-subtitle>
            </v-card-item>

            <v-divider></v-divider>

            <v-card-text>
              <v-list density="compact" class="bg-transparent">
                <v-list-item>
                  <template v-slot:prepend>
                    <v-icon icon="mdi-cookie" color="warning"></v-icon>
                  </template>
                  <v-list-item-title>Cookies</v-list-item-title>
                  <v-list-item-subtitle class="text-h6 font-weight-bold text-warning">
                    {{ me.cookies }}
                  </v-list-item-subtitle>
                </v-list-item>

                <v-list-item>
                  <template v-slot:prepend>
                    <v-icon icon="mdi-speedometer" color="success"></v-icon>
                  </template>
                  <v-list-item-title>Per Second</v-list-item-title>
                  <v-list-item-subtitle class="text-subtitle-1 font-weight-medium text-success">
                    {{ me.cookiesPerSecond }}/s
                  </v-list-item-subtitle>
                </v-list-item>

                <v-list-item v-if="myPrivate">
                  <template v-slot:prepend>
                    <v-icon icon="mdi-cursor-default-click" color="info"></v-icon>
                  </template>
                  <v-list-item-title>Total Clicks</v-list-item-title>
                  <v-list-item-subtitle class="text-subtitle-1">
                    {{ myPrivate.totalClicks }}
                  </v-list-item-subtitle>
                </v-list-item>
              </v-list>
            </v-card-text>
          </v-card>

          <!-- Cookie Click Card -->
          <v-card variant="outlined" class="mb-4">
            <v-card-text class="pa-6 text-center">
              <v-btn
                color="warning"
                size="x-large"
                variant="flat"
                @click="handleClick"
                prepend-icon="mdi-cookie"
                block
                class="btn-cookie text-h6"
                data-testid="cookie-click"
              >
                Click Cookie!
              </v-btn>
            </v-card-text>
          </v-card>

          <!-- Upgrades Card -->
          <v-card variant="outlined">
            <v-card-title class="bg-surface-variant">
              <v-icon icon="mdi-storefront" class="mr-2"></v-icon>
              Shop Upgrades
            </v-card-title>

            <v-divider></v-divider>

            <v-card-text class="pa-4">
              <v-row>
                <!-- Cursor Upgrade -->
                <v-col cols="12" sm="6">
                  <v-card variant="outlined" :class="{ 'border-success': canAffordCursor }">
                    <v-card-item>
                      <template v-slot:prepend>
                        <v-avatar color="info" size="40">
                          <v-icon icon="mdi-cursor-default-click"></v-icon>
                        </v-avatar>
                      </template>
                      <v-card-title class="text-subtitle-1">Cursor</v-card-title>
                      <v-card-subtitle>
                        <v-chip size="x-small" color="info" variant="flat" class="mr-1">
                          Lv {{ cursorLevel }}
                        </v-chip>
                      </v-card-subtitle>
                    </v-card-item>

                    <v-card-text>
                      <div class="d-flex justify-space-between align-center mb-2">
                        <span class="text-caption text-medium-emphasis">Cost:</span>
                        <v-chip size="small" :color="canAffordCursor ? 'success' : 'grey'">
                          {{ cursorCost }}
                          <v-icon icon="mdi-cookie" size="x-small" class="ml-1"></v-icon>
                        </v-chip>
                      </div>
                    </v-card-text>

                    <v-card-actions>
                      <v-btn
                        color="info"
                        variant="flat"
                        block
                        :disabled="!canAffordCursor"
                        @click="handleBuy('cursor')"
                      >
                        <v-icon icon="mdi-cart" class="mr-1"></v-icon>
                        Buy
                      </v-btn>
                    </v-card-actions>
                  </v-card>
                </v-col>

                <!-- Grandma Upgrade -->
                <v-col cols="12" sm="6">
                  <v-card variant="outlined" :class="{ 'border-success': canAffordGrandma }">
                    <v-card-item>
                      <template v-slot:prepend>
                        <v-avatar color="purple" size="40">
                          <v-icon icon="mdi-human-female"></v-icon>
                        </v-avatar>
                      </template>
                      <v-card-title class="text-subtitle-1">Grandma</v-card-title>
                      <v-card-subtitle>
                        <v-chip size="x-small" color="purple" variant="flat" class="mr-1">
                          Lv {{ grandmaLevel }}
                        </v-chip>
                      </v-card-subtitle>
                    </v-card-item>

                    <v-card-text>
                      <div class="d-flex justify-space-between align-center mb-2">
                        <span class="text-caption text-medium-emphasis">Cost:</span>
                        <v-chip size="small" :color="canAffordGrandma ? 'success' : 'grey'">
                          {{ grandmaCost }}
                          <v-icon icon="mdi-cookie" size="x-small" class="ml-1"></v-icon>
                        </v-chip>
                      </div>
                    </v-card-text>

                    <v-card-actions>
                      <v-btn
                        color="purple"
                        variant="flat"
                        block
                        :disabled="!canAffordGrandma"
                        @click="handleBuy('grandma')"
                      >
                        <v-icon icon="mdi-cart" class="mr-1"></v-icon>
                        Buy
                      </v-btn>
                    </v-card-actions>
                  </v-card>
                </v-col>
              </v-row>
            </v-card-text>
          </v-card>
        </v-col>

        <!-- Right Column: Room Stats & Players -->
        <v-col cols="12" lg="6">
          <!-- Room Stats Card -->
          <v-card variant="outlined" class="mb-4">
            <v-card-title class="bg-surface-variant">
              <v-icon icon="mdi-chart-bar" class="mr-2"></v-icon>
              Room Statistics
            </v-card-title>

            <v-divider></v-divider>

            <v-card-text>
              <v-list density="compact" class="bg-transparent">
                <v-list-item>
                  <template v-slot:prepend>
                    <v-icon icon="mdi-cookie-multiple" color="warning"></v-icon>
                  </template>
                  <v-list-item-title>Total Cookies Baked</v-list-item-title>
                  <v-list-item-subtitle class="text-h6 font-weight-bold">
                    {{ state.totalCookies ?? 0 }}
                  </v-list-item-subtitle>
                </v-list-item>

                <v-list-item>
                  <template v-slot:prepend>
                    <v-icon icon="mdi-account-group" color="info"></v-icon>
                  </template>
                  <v-list-item-title>Active Players</v-list-item-title>
                  <v-list-item-subtitle class="text-subtitle-1 font-weight-medium">
                    {{ Object.keys(state.players ?? {}).length }}
                  </v-list-item-subtitle>
                </v-list-item>

                <v-list-item>
                  <template v-slot:prepend>
                    <v-icon icon="mdi-clock-outline" color="grey"></v-icon>
                  </template>
                  <v-list-item-title>Server Ticks</v-list-item-title>
                  <v-list-item-subtitle class="text-caption">
                    {{ state.ticks ?? 0 }}
                  </v-list-item-subtitle>
                </v-list-item>
              </v-list>
            </v-card-text>
          </v-card>

          <!-- Other Players Card -->
          <v-card v-if="others.length > 0" variant="outlined" class="mb-4">
            <v-card-title class="bg-surface-variant">
              <v-icon icon="mdi-account-multiple" class="mr-2"></v-icon>
              Other Players ({{ others.length }})
            </v-card-title>

            <v-divider></v-divider>

            <v-card-text class="pa-2">
              <v-list density="compact" class="bg-transparent">
                <v-list-item
                  v-for="p in others"
                  :key="p.id"
                  :title="p.name || p.id"
                  :subtitle="`${p.cookiesPerSecond}/s`"
                >
                  <template v-slot:prepend>
                    <v-avatar color="grey-lighten-1" size="32">
                      <v-icon icon="mdi-account" size="small"></v-icon>
                    </v-avatar>
                  </template>

                  <template v-slot:append>
                    <v-chip size="small" color="warning" variant="flat">
                      {{ p.cookies }}
                      <v-icon icon="mdi-cookie" size="x-small" class="ml-1"></v-icon>
                    </v-chip>
                  </template>
                </v-list-item>
              </v-list>
            </v-card-text>
          </v-card>

          <!-- Leave Button -->
          <v-btn
            color="grey-darken-1"
            variant="tonal"
            prepend-icon="mdi-arrow-left"
            block
            @click="handleLeave"
          >
            Leave Game
          </v-btn>
        </v-col>
      </v-row>
    </div>
  </v-container>
</template>

<style scoped>
.cookie-game-page {
  max-width: 100%;
  padding-top: 16px;
}

.btn-cookie {
  font-size: 1.25rem !important;
  padding: 32px 24px !important;
  letter-spacing: 0.05em;
}

.border-success {
  border-color: rgb(var(--v-theme-success)) !important;
  border-width: 2px !important;
}
</style>
