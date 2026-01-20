<script setup lang="ts">
import { computed, ref, onMounted, onUnmounted, watch } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import { useCookie } from '../generated/cookie/useCookie'
import {
  filterOtherPlayers,
  getCurrentPlayer,
  getCurrentPlayerPrivateState,
  getUpgradeLevel,
  calculateUpgradeCost
} from '../utils/gameLogic'
import DemoLayout from '../components/demo/DemoLayout.vue'
import ConnectionStatusCard from '../components/demo/ConnectionStatusCard.vue'
import AuthorityHint from '../components/demo/AuthorityHint.vue'
import CookieStateInspector from '../components/demo/cookie/CookieStateInspector.vue'

const router = useRouter()
const route = useRoute()

// Room ID from query parameter
const roomId = ref<string>((route.query.roomId as string) || 'default')

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
    connected.value = true
    error.value = undefined
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Failed to connect'
    connected.value = false
    console.error('Failed to connect:', e)
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
  <DemoLayout
    title="Cookie Clicker"
    :room-id="roomId"
    land-type="cookie"
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
      <!-- Left Column: Player Actions -->
      <v-col cols="12" lg="6">
        <!-- Cookie Click Card (Core Action) -->
        <v-card variant="outlined" class="mb-4">
          <v-card-title class="bg-surface-variant py-2 d-flex align-center">
            <v-icon icon="mdi-cookie" size="small" class="mr-2" />
            <span class="text-subtitle-1">Click Action</span>
          </v-card-title>
          <v-card-text class="pa-4">
            <p class="text-body-2 text-medium-emphasis mb-4">
              Click the cookie to send a <code>clickCookie</code> action.
              Server processes the click and updates your cookies count.
            </p>
            <v-btn
              color="warning"
              size="x-large"
              variant="flat"
              :disabled="!isJoined"
              :loading="!connected"
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

        <!-- Upgrades Card (Core Action) -->
        <v-card variant="outlined">
          <v-card-title class="bg-surface-variant py-2 d-flex align-center">
            <v-icon icon="mdi-storefront" size="small" class="mr-2" />
            <span class="text-subtitle-1">Shop Upgrades</span>
          </v-card-title>

          <v-card-text class="pa-4">
            <p class="text-body-2 text-medium-emphasis mb-4">
              Purchase upgrades to increase cookies/sec.
              Server validates costs and applies upgrades.
            </p>
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

      <!-- Right Column: State Inspector & Room Stats -->
      <v-col cols="12" lg="6">
        <!-- State Inspector -->
        <CookieStateInspector
          :snapshot="state"
          :last-updated-at="lastStateAt"
          class="mb-4"
        />

        <!-- Room Stats Card -->
        <v-card variant="outlined" class="mb-4">
          <v-card-title class="bg-surface-variant py-2 d-flex align-center">
            <v-icon icon="mdi-chart-bar" size="small" class="mr-2" />
            <span class="text-subtitle-1">Room Statistics</span>
          </v-card-title>

          <v-card-text class="pa-4">
            <v-list density="compact" class="bg-transparent">
              <v-list-item>
                <template v-slot:prepend>
                  <v-icon icon="mdi-cookie-multiple" color="warning"></v-icon>
                </template>
                <v-list-item-title>Total Cookies Baked</v-list-item-title>
                <v-list-item-subtitle class="text-h6 font-weight-bold">
                  {{ state?.totalCookies ?? 0 }}
                </v-list-item-subtitle>
              </v-list-item>

              <v-list-item>
                <template v-slot:prepend>
                  <v-icon icon="mdi-account-group" color="info"></v-icon>
                </template>
                <v-list-item-title>Active Players</v-list-item-title>
                <v-list-item-subtitle class="text-subtitle-1 font-weight-medium">
                  {{ Object.keys(state?.players ?? {}).length }}
                </v-list-item-subtitle>
              </v-list-item>

              <v-list-item>
                <template v-slot:prepend>
                  <v-icon icon="mdi-clock-outline" color="grey"></v-icon>
                </template>
                <v-list-item-title>Server Ticks</v-list-item-title>
                <v-list-item-subtitle class="text-caption">
                  {{ state?.ticks ?? 0 }}
                </v-list-item-subtitle>
              </v-list-item>
            </v-list>
          </v-card-text>
        </v-card>

        <!-- Other Players Card -->
        <v-card v-if="others.length > 0" variant="outlined" class="mb-4">
          <v-card-title class="bg-surface-variant py-2 d-flex align-center">
            <v-icon icon="mdi-account-multiple" size="small" class="mr-2" />
            <span class="text-subtitle-1">Other Players ({{ others.length }})</span>
          </v-card-title>

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
  </DemoLayout>
</template>

<style scoped>
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
