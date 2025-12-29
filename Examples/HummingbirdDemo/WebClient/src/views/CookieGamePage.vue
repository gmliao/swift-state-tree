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
</script>

<template>
  <div class="container">
    <div class="header">
      <h1>🍪 Cookie Clicker</h1>
      <button @click="handleLeave" class="btn btn-small">Leave Game</button>
    </div>

    <div v-if="isConnecting" class="section">
      <p>Connecting to room...</p>
    </div>

    <div v-if="!isJoined || !state" class="section" v-show="!isConnecting">
      <p>Not connected. Please go back to home and connect.</p>
      <button @click="handleLeave" class="btn btn-primary">Go Home</button>
    </div>

    <div v-else class="game-grid">
      <!-- Left Column: Player Info & Actions -->
      <div class="left-column">
      <!-- My Status -->
      <div v-if="me" class="card">
        <h2>{{ me.name || 'You' }}</h2>
        <div class="stats">
            <div class="stat-item">
              <span class="stat-label">Cookies:</span>
              <span class="stat-value">{{ me.cookies }}</span>
            </div>
            <div class="stat-item">
              <span class="stat-label">Per Second:</span>
              <span class="stat-value">{{ me.cookiesPerSecond }}</span>
            </div>
            <div v-if="myPrivate" class="stat-item">
              <span class="stat-label">Total Clicks:</span>
              <span class="stat-value">{{ myPrivate.totalClicks }}</span>
            </div>
        </div>
      </div>

      <!-- Actions -->
      <div class="card">
        <button @click="handleClick" class="btn btn-large btn-cookie">
          🍪 Click Cookie!
        </button>

        <div class="upgrades">
          <div class="upgrade">
            <h3>Cursor</h3>
              <div class="upgrade-info">
                <p>Level: <strong>{{ cursorLevel }}</strong></p>
                <p>Cost: <strong>{{ cursorCost }}</strong> cookies</p>
              </div>
              <button @click="handleBuy('cursor')" class="btn btn-upgrade">Buy</button>
          </div>
          <div class="upgrade">
            <h3>Grandma</h3>
              <div class="upgrade-info">
                <p>Level: <strong>{{ grandmaLevel }}</strong></p>
                <p>Cost: <strong>{{ grandmaCost }}</strong> cookies</p>
              </div>
              <button @click="handleBuy('grandma')" class="btn btn-upgrade">Buy</button>
            </div>
          </div>
        </div>
      </div>

      <!-- Right Column: Room Stats & Other Players -->
      <div class="right-column">
      <!-- Room Info -->
      <div class="card">
        <h2>Room Stats</h2>
        <div class="stats">
            <div class="stat-item">
              <span class="stat-label">Total Cookies:</span>
              <span class="stat-value">{{ state.totalCookies ?? 0 }}</span>
            </div>
            <div class="stat-item">
              <span class="stat-label">Players:</span>
              <span class="stat-value">{{ Object.keys(state.players ?? {}).length }}</span>
            </div>
            <div class="stat-item">
              <span class="stat-label">Ticks:</span>
              <span class="stat-value">{{ state.ticks ?? 0 }}</span>
            </div>
        </div>
      </div>

      <!-- Other Players -->
      <div v-if="others.length > 0" class="card">
        <h2>Other Players</h2>
          <div class="players-list">
        <div v-for="p in others" :key="p.id" class="player">
              <div class="player-name">{{ p.name || p.id }}</div>
              <div class="player-stats">
                <span>{{ p.cookies }} cookies</span>
                <span class="player-cps">{{ p.cookiesPerSecond }}/s</span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.container {
  max-width: 1400px;
  margin: 0 auto;
  padding: 20px;
}

.header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 2rem;
}

h1 {
  font-size: 2rem;
  margin: 0;
}

h2 {
  font-size: 1.5rem;
  margin-bottom: 1rem;
  color: #333;
}

h3 {
  font-size: 1.2rem;
  margin-bottom: 0.75rem;
  color: #555;
}

.section {
  background: #f9f9f9;
  border: 1px solid #ddd;
  border-radius: 8px;
  padding: 2rem;
  text-align: center;
}

/* Grid Layout */
.game-grid {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 1.5rem;
  align-items: start;
}

.left-column,
.right-column {
  display: flex;
  flex-direction: column;
  gap: 1.5rem;
  align-items: stretch;
}

.card {
  background: #f9f9f9;
  border: 1px solid #ddd;
  border-radius: 8px;
  padding: 1.5rem;
  box-shadow: 0 2px 4px rgba(0, 0, 0, 0.1);
  width: 100%;
  box-sizing: border-box;
}

.stats {
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
}

.stat-item {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 0.5rem 0;
  border-bottom: 1px solid #eee;
}

.stat-item:last-child {
  border-bottom: none;
}

.stat-label {
  color: #666;
  font-weight: 500;
}

.stat-value {
  color: #333;
  font-weight: 600;
  font-size: 1.1rem;
}

.btn {
  padding: 0.5rem 1rem;
  border: none;
  border-radius: 4px;
  font-size: 1rem;
  cursor: pointer;
  transition: all 0.2s;
}

.btn-primary {
  background-color: #4CAF50;
  color: white;
}

.btn-primary:hover {
  background-color: #45a049;
}

.btn-small {
  padding: 0.5rem 1rem;
  font-size: 0.875rem;
  background-color: #666;
  color: white;
}

.btn-small:hover {
  background-color: #555;
}

.btn-large {
  padding: 1rem 2rem;
  font-size: 1.2rem;
}

.btn-cookie {
  background-color: #FF9800;
  color: white;
  width: 100%;
  margin-bottom: 1.5rem;
  font-weight: 600;
}

.btn-cookie:hover {
  background-color: #F57C00;
  transform: scale(1.02);
}

.btn-upgrade {
  background-color: #2196F3;
  color: white;
  width: 100%;
  margin-top: 0.75rem;
}

.btn-upgrade:hover {
  background-color: #1976D2;
}

.upgrades {
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  gap: 1rem;
  margin-top: 1rem;
}

.upgrade {
  background: white;
  border: 1px solid #ddd;
  border-radius: 4px;
  padding: 1rem;
  text-align: center;
}

.upgrade-info {
  margin: 0.5rem 0;
}

.upgrade-info p {
  margin: 0.25rem 0;
  font-size: 0.9rem;
}

.players-list {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
}

.player {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 0.75rem;
  background: white;
  border: 1px solid #eee;
  border-radius: 4px;
}

.player-name {
  font-weight: 600;
  color: #333;
}

.player-stats {
  display: flex;
  gap: 0.75rem;
  align-items: center;
  color: #666;
  font-size: 0.9rem;
}

.player-cps {
  color: #4CAF50;
  font-weight: 500;
}

p {
  margin: 0.5rem 0;
}


/* Responsive Design */
@media (max-width: 1024px) {
  .game-grid {
    grid-template-columns: 1fr;
  }
  
  .upgrades {
    grid-template-columns: 1fr;
  }
}

@media (max-width: 768px) {
  .container {
    padding: 15px;
  }
  
  .header {
    flex-direction: column;
    gap: 1rem;
    align-items: flex-start;
  }
  
  h1 {
    font-size: 1.5rem;
  }
}
</style>
