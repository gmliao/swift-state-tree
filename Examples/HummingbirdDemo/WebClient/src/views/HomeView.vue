<script setup lang="ts">
import { ref, watch } from 'vue'
import { useRouter } from 'vue-router'
import { useDemoGame } from '../generated/demo-game/useDemoGame'

const router = useRouter()

const wsUrl = ref('ws://localhost:8080/game')
const playerName = ref('')

const {
  isConnecting,
  isConnected,
  isJoined,
  lastError,
  connect,
  disconnect
} = useDemoGame()

// Auto redirect to game page when joined
watch(isJoined, (joined) => {
  if (joined) {
    router.push({ name: 'cookie-game' })
  }
})

async function handleConnect() {
  await connect({
    wsUrl: wsUrl.value,
    playerName: playerName.value || undefined
  })
}

async function handleDisconnect() {
  await disconnect()
}
</script>

<template>
  <div class="container">
    <h1>🍪 Cookie Clicker Demo</h1>

    <div class="section">
      <h2>Connect to Game</h2>
      <div class="form">
        <input
          v-model="wsUrl"
          placeholder="WebSocket URL"
          class="input"
        />
        <input
          v-model="playerName"
          placeholder="Your name (optional)"
          class="input"
        />
        <button
          @click="handleConnect"
          :disabled="isConnecting || isConnected"
          class="btn btn-primary"
        >
          {{ isConnecting ? 'Connecting...' : 'Connect & Join' }}
        </button>
        <button
          v-if="isConnected"
          @click="handleDisconnect"
          class="btn btn-secondary"
        >
          Disconnect
        </button>
      </div>
      <div v-if="lastError" class="error">{{ lastError }}</div>
      <div v-if="isConnected && !isJoined" class="info">Connected, joining game...</div>
      <div v-if="isJoined" class="success">Joined! Redirecting to game...</div>
    </div>
  </div>
</template>

<style scoped>
.container {
  max-width: 600px;
  margin: 0 auto;
  padding: 40px 20px;
}

h1 {
  text-align: center;
  font-size: 2.5rem;
  margin-bottom: 2rem;
}

h2 {
  font-size: 1.5rem;
  margin-bottom: 1rem;
}

.section {
  background: #f9f9f9;
  border: 1px solid #ddd;
  border-radius: 8px;
  padding: 2rem;
}

.form {
  display: flex;
  flex-direction: column;
  gap: 1rem;
  margin-bottom: 1rem;
}

.input {
  padding: 0.75rem;
  border: 1px solid #ddd;
  border-radius: 4px;
  font-size: 1rem;
}

.btn {
  padding: 0.75rem 1.5rem;
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

.btn-primary:hover:not(:disabled) {
  background-color: #45a049;
}

.btn-primary:disabled {
  background-color: #ccc;
  cursor: not-allowed;
}

.btn-secondary {
  background-color: #f44336;
  color: white;
}

.btn-secondary:hover {
  background-color: #da190b;
}

.error {
  color: #f44336;
  padding: 0.75rem;
  background: #ffebee;
  border-radius: 4px;
  margin-top: 1rem;
}

.info {
  color: #2196F3;
  padding: 0.75rem;
  background: #e3f2fd;
  border-radius: 4px;
  margin-top: 1rem;
}

.success {
  color: #4CAF50;
  padding: 0.75rem;
  background: #e8f5e9;
  border-radius: 4px;
  margin-top: 1rem;
}
</style>
