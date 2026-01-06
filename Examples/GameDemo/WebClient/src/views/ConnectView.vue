<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { useRouter } from 'vue-router'

const router = useRouter()

// Generate random user name: user-[五位數字]
function generateRandomUserName(): string {
  const randomNum = Math.floor(Math.random() * 100000).toString().padStart(5, '0')
  return `user-${randomNum}`
}

const wsUrl = ref('ws://localhost:8080/game/hero-defense')
const playerName = ref('')
const roomId = ref('default')
const error = ref<string | null>(null)
const isConnecting = ref(false)

// Auto-generate player name on mount
onMounted(() => {
  if (!playerName.value) {
    playerName.value = generateRandomUserName()
  }
})

async function handleConnect() {
  if (isConnecting.value) return
  
  // Validate inputs
  if (!wsUrl.value.trim()) {
    error.value = '請輸入 WebSocket 網址'
    return
  }
  
  if (!playerName.value.trim()) {
    error.value = '請輸入玩家名稱'
    return
  }
  
  error.value = null
  isConnecting.value = true
  
  try {
    // Store connection info in sessionStorage
    sessionStorage.setItem('wsUrl', wsUrl.value.trim())
    sessionStorage.setItem('playerName', playerName.value.trim())
    sessionStorage.setItem('roomId', roomId.value.trim())
    
    // Navigate to game view
    await router.push({ name: 'game' })
  } catch (err) {
    error.value = err instanceof Error ? err.message : '連接失敗'
  } finally {
    isConnecting.value = false
  }
}
</script>

<template>
  <v-container fluid class="fill-height d-flex align-center justify-center">
    <v-card width="500" class="pa-6" elevation="4">
      <v-card-title class="text-h4 mb-2">
        🎮 Hero Defense
      </v-card-title>
      
      <v-card-subtitle class="mb-6 text-medium-emphasis">
        輸入連接資訊開始遊戲
      </v-card-subtitle>
      
      <v-form @submit.prevent="handleConnect">
        <v-text-field
          v-model="wsUrl"
          label="WebSocket 網址"
          placeholder="ws://localhost:8080/game/hero-defense"
          prepend-inner-icon="mdi-web"
          variant="outlined"
          class="mb-4"
          :disabled="isConnecting"
        />
        
        <v-text-field
          v-model="playerName"
          label="玩家名稱"
          placeholder="輸入你的名稱"
          prepend-inner-icon="mdi-account"
          variant="outlined"
          class="mb-4"
          :disabled="isConnecting"
          required
        />
        
        <v-text-field
          v-model="roomId"
          label="房間 ID (選填)"
          placeholder="留空則自動創建新房間"
          prepend-inner-icon="mdi-door"
          variant="outlined"
          class="mb-4"
          :disabled="isConnecting"
          hint="留空則自動創建新房間"
          persistent-hint
        />
        
        <v-alert
          v-if="error"
          type="error"
          variant="tonal"
          class="mb-4"
        >
          {{ error }}
        </v-alert>
        
        <v-btn
          type="submit"
          color="primary"
          size="large"
          block
          :loading="isConnecting"
          :disabled="isConnecting"
          variant="flat"
        >
          <v-icon start>mdi-play</v-icon>
          開始遊戲
        </v-btn>
      </v-form>
    </v-card>
  </v-container>
</template>

<style scoped>
.fill-height {
  height: 100vh;
}
</style>
