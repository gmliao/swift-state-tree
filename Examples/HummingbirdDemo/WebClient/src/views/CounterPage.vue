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
  <div class="container">
    <div class="header">
      <h1>🔢 Counter Demo</h1>
      <button @click="handleLeave" class="btn btn-small">Leave</button>
    </div>

    <div v-if="!isJoined || !state" class="section">
      <p>Connecting...</p>
    </div>

    <div v-else class="counter-section">
      <div class="counter-display">
        <h2>Count: {{ state.count ?? 0 }}</h2>
      </div>
      <button @click="handleIncrement" class="btn btn-primary btn-large">
        +1
      </button>
      <p class="info">This is the simplest SwiftStateTree example!</p>
    </div>
  </div>
</template>

<style scoped>
.container {
  max-width: 600px;
  margin: 0 auto;
  padding: 40px 20px;
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
  font-size: 3rem;
  margin: 2rem 0;
  color: #333;
  text-align: center;
}

.section {
  background: #f9f9f9;
  border: 1px solid #ddd;
  border-radius: 8px;
  padding: 2rem;
  text-align: center;
}

.counter-section {
  text-align: center;
}

.counter-display {
  background: #f9f9f9;
  border: 2px solid #4CAF50;
  border-radius: 12px;
  padding: 3rem 2rem;
  margin-bottom: 2rem;
}

.btn {
  padding: 0.75rem 1.5rem;
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

.btn-primary:hover:not(:disabled) {
  background-color: #45a049;
}

.btn-primary:disabled {
  background-color: #ccc;
  cursor: not-allowed;
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
  padding: 1.5rem 3rem;
  font-size: 1.5rem;
  font-weight: 600;
  min-width: 200px;
}

.info {
  margin-top: 2rem;
  color: #666;
  font-style: italic;
}
</style>
