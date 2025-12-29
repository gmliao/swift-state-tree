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
  <div class="container">
    <h1>SwiftStateTree Demos</h1>

    <!-- Room ID Input -->
    <div class="room-input-section">
      <label for="roomId">Room ID (optional):</label>
      <input
        id="roomId"
        v-model="roomId"
        type="text"
        placeholder="e.g., room-123 (leave empty for new room)"
        class="room-input"
      />
      <p class="room-hint">Leave empty to create a new room, or enter a room ID to join an existing room.</p>
    </div>

    <div class="demos">
      <div class="demo-card" @click="goToCounter">
        <h2>🔢 Counter Demo</h2>
        <p>The simplest example: a shared counter that increments on click.</p>
        <p class="demo-note">Perfect for understanding the basics!</p>
        <button class="btn btn-primary">Try Counter Demo</button>
      </div>

      <div class="demo-card" @click="goToCookie">
        <h2>🍪 Cookie Clicker</h2>
        <p>A full multiplayer game with upgrades, private state, and tick-based logic.</p>
        <p class="demo-note">Advanced example with multiple features.</p>
        <button class="btn btn-primary">Try Cookie Clicker</button>
      </div>
    </div>
  </div>
</template>

<style scoped>
.container {
  max-width: 1000px;
  margin: 0 auto;
  padding: 40px 20px;
}

h1 {
  text-align: center;
  font-size: 2.5rem;
  margin-bottom: 2rem;
}

.room-input-section {
  max-width: 600px;
  margin: 0 auto 3rem;
  padding: 1.5rem;
  background: #f9f9f9;
  border: 2px solid #ddd;
  border-radius: 8px;
}

.room-input-section label {
  display: block;
  font-weight: 600;
  color: #333;
  margin-bottom: 0.5rem;
}

.room-input {
  width: 100%;
  padding: 0.75rem;
  border: 2px solid #ddd;
  border-radius: 4px;
  font-size: 1rem;
  box-sizing: border-box;
  margin-bottom: 0.5rem;
}

.room-input:focus {
  outline: none;
  border-color: #4CAF50;
}

.room-hint {
  font-size: 0.875rem;
  color: #666;
  font-style: italic;
  margin: 0;
}

.demos {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
  gap: 2rem;
}

.demo-card {
  background: #f9f9f9;
  border: 2px solid #ddd;
  border-radius: 12px;
  padding: 2rem;
  cursor: pointer;
  transition: all 0.3s;
  text-align: center;
}

.demo-card:hover {
  border-color: #4CAF50;
  transform: translateY(-4px);
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.1);
}

.demo-card h2 {
  font-size: 1.8rem;
  margin-bottom: 1rem;
  color: #333;
}

.demo-card p {
  color: #666;
  line-height: 1.6;
  margin-bottom: 0.5rem;
}

.demo-note {
  font-style: italic;
  color: #999;
  font-size: 0.9rem;
  margin-bottom: 1.5rem !important;
}

.btn {
  padding: 0.75rem 1.5rem;
  border: none;
  border-radius: 4px;
  font-size: 1rem;
  cursor: pointer;
  transition: background-color 0.2s;
  width: 100%;
}

.btn-primary {
  background-color: #4CAF50;
  color: white;
}

.btn-primary:hover {
  background-color: #45a049;
}

@media (max-width: 768px) {
  .demos {
    grid-template-columns: 1fr;
  }
}
</style>
