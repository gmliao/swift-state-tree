<script setup lang="ts">
import { computed } from 'vue'
import { useRouter } from 'vue-router'
import { useDemoGame } from '../generated/demo-game/useDemoGame'

const router = useRouter()

const {
  state,
  currentPlayerID,
  isJoined,
  disconnect,
  clickCookie,
  buyUpgrade
} = useDemoGame()

// Simple computed for current player
const me = computed(() => {
  if (!state.value || !currentPlayerID.value) return null
  return state.value.players?.[currentPlayerID.value] ?? null
})

const myPrivate = computed(() => {
  if (!state.value || !currentPlayerID.value) return null
  return state.value.privateStates?.[currentPlayerID.value] ?? null
})

const others = computed(() => {
  if (!state.value || !currentPlayerID.value) return []
  return Object.entries(state.value.players ?? {})
    .filter(([id]) => id !== currentPlayerID.value)
    .map(([id, p]) => ({ id, ...p }))
})

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

const cursorLevel = computed(() => myPrivate.value?.upgrades?.cursor ?? 0)
const grandmaLevel = computed(() => myPrivate.value?.upgrades?.grandma ?? 0)
</script>

<template>
  <div class="container">
    <div class="header">
      <h1>🍪 Cookie Clicker</h1>
      <button @click="handleLeave" class="btn btn-small">Leave Game</button>
    </div>

    <div v-if="!isJoined || !state" class="section">
      <p>Not connected. Please go back to home and connect.</p>
      <button @click="handleLeave" class="btn btn-primary">Go Home</button>
    </div>

    <div v-else>
      <!-- My Status -->
      <div v-if="me" class="card">
        <h2>{{ me.name || 'You' }}</h2>
        <div class="stats">
          <p><strong>Cookies:</strong> {{ me.cookies }}</p>
          <p><strong>Per Second:</strong> {{ me.cookiesPerSecond }}</p>
          <p v-if="myPrivate"><strong>Total Clicks:</strong> {{ myPrivate.totalClicks }}</p>
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
            <p>Level: {{ cursorLevel }}</p>
            <p>Cost: {{ 10 * (cursorLevel + 1) }} cookies</p>
            <button @click="handleBuy('cursor')" class="btn">Buy</button>
          </div>
          <div class="upgrade">
            <h3>Grandma</h3>
            <p>Level: {{ grandmaLevel }}</p>
            <p>Cost: {{ 50 * (grandmaLevel + 1) }} cookies</p>
            <button @click="handleBuy('grandma')" class="btn">Buy</button>
          </div>
        </div>
      </div>

      <!-- Room Info -->
      <div class="card">
        <h2>Room Stats</h2>
        <div class="stats">
          <p><strong>Total Cookies:</strong> {{ state.totalCookies ?? 0 }}</p>
          <p><strong>Players:</strong> {{ Object.keys(state.players ?? {}).length }}</p>
          <p><strong>Ticks:</strong> {{ state.ticks ?? 0 }}</p>
        </div>
      </div>

      <!-- Other Players -->
      <div v-if="others.length > 0" class="card">
        <h2>Other Players</h2>
        <div v-for="p in others" :key="p.id" class="player">
          <strong>{{ p.name || p.id }}</strong>
          <span>{{ p.cookies }} cookies ({{ p.cookiesPerSecond }}/s)</span>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.container {
  max-width: 900px;
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
}

h3 {
  font-size: 1.2rem;
  margin-bottom: 0.5rem;
}

.section {
  background: #f9f9f9;
  border: 1px solid #ddd;
  border-radius: 8px;
  padding: 2rem;
  text-align: center;
}

.card {
  background: #f9f9f9;
  border: 1px solid #ddd;
  border-radius: 8px;
  padding: 1.5rem;
  margin-bottom: 1rem;
}

.stats {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
}

.btn {
  padding: 0.5rem 1rem;
  border: none;
  border-radius: 4px;
  font-size: 1rem;
  cursor: pointer;
  transition: background-color 0.2s;
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
}

.btn-cookie:hover {
  background-color: #F57C00;
}

.upgrades {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
  gap: 1rem;
}

.upgrade {
  background: white;
  border: 1px solid #ddd;
  border-radius: 4px;
  padding: 1rem;
  text-align: center;
}

.player {
  display: flex;
  justify-content: space-between;
  padding: 0.75rem 0;
  border-bottom: 1px solid #eee;
}

.player:last-child {
  border-bottom: none;
}

p {
  margin: 0.5rem 0;
}
</style>
