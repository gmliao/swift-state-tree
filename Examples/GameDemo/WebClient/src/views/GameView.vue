<script setup lang="ts">
import { ref, onMounted, onUnmounted } from 'vue'
import { useRouter } from 'vue-router'
import Phaser from 'phaser'
import { GameScene } from '../scenes/GameScene'
import { useGameClient } from '../utils/gameClient'

const router = useRouter()
const gameRef = ref<HTMLDivElement | null>(null)
const phaserGame = ref<Phaser.Game | null>(null)
const { state, isConnected, isJoined, isConnecting, lastError, connect, disconnect, play } = useGameClient()

onMounted(async () => {
  console.log('[GameView] onMounted called')
  // Get connection info from sessionStorage
  const wsUrl = sessionStorage.getItem('wsUrl')
  const playerName = sessionStorage.getItem('playerName')
  const roomId = sessionStorage.getItem('roomId')
  
  console.log('[GameView] Connection info:', { wsUrl, playerName, roomId })
  
  if (!wsUrl || !playerName) {
    console.log('[GameView] Missing connection info, redirecting to connect page')
    router.push({ name: 'connect' })
    return
  }
  
  try {
    console.log('[GameView] Starting connection...')
    // Connect to server and wait for join to complete
    await connect({
      wsUrl,
      playerName,
      landID: roomId || undefined
    })
    console.log('[GameView] Connection completed, isJoined:', isJoined.value)
    
    // Only initialize Phaser after successful connection and join
    if (!isJoined.value) {
      console.error('[GameView] Connection succeeded but not joined')
      return
    }
    
    // Initialize Phaser game only after successful join
    if (gameRef.value && isJoined.value) {
      // Get available space (viewport width and height minus toolbar)
      const availableWidth = Math.min(window.innerWidth, 1280)
      const availableHeight = Math.min(window.innerHeight - 64, 720)
      
      // Create game client object before initializing Phaser
      const gameClient = { state, play }
      
      phaserGame.value = new Phaser.Game({
        type: Phaser.AUTO,
        width: availableWidth,
        height: availableHeight,
        parent: gameRef.value,
        backgroundColor: '#ffffff',
        scene: [GameScene],
        physics: {
          default: 'arcade',
          arcade: {
            gravity: { x: 0, y: 0 },
            debug: false
          }
        },
        scale: {
          mode: Phaser.Scale.FIT,
          autoCenter: Phaser.Scale.CENTER_BOTH
        }
      })
      
      // Wait for scene to be fully initialized, then set game client
      await new Promise(resolve => setTimeout(resolve, 100))
      
      // Pass game client to scene
      const scene = phaserGame.value.scene.getScene('GameScene') as GameScene
      if (scene) {
        console.log('[GameView] Setting gameClient on scene')
        scene.setGameClient(gameClient)
        console.log('[GameView] gameClient set successfully')
      } else {
        console.error('[GameView] Scene not found!')
      }
    }
  } catch (error) {
    console.error('[GameView] Failed to connect:', error)
    // Error is already stored in lastError by useGameClient
    // Don't navigate away immediately, let user see the error
  }
})

onUnmounted(async () => {
  if (phaserGame.value) {
    phaserGame.value.destroy(true)
    phaserGame.value = null
  }
  await disconnect()
})

async function handleLeave() {
  // Disconnect before leaving
  await disconnect()
  // Clear session storage
  sessionStorage.removeItem('wsUrl')
  sessionStorage.removeItem('playerName')
  sessionStorage.removeItem('roomId')
  // Navigate back to connect page
  router.push({ name: 'connect' })
}
</script>

<template>
  <v-app>
    <v-app-bar color="primary" prominent app>
      <v-toolbar-title>
        <v-icon start>mdi-gamepad-variant</v-icon>
        Hero Defense
      </v-toolbar-title>
      
      <v-spacer />
      
      <v-chip
        :color="isConnected ? 'success' : 'error'"
        variant="flat"
        class="mr-2"
      >
        {{ isConnected ? '已連接' : '未連接' }}
      </v-chip>
      
      <v-chip
        v-if="isJoined"
        color="info"
        variant="flat"
        class="mr-2"
      >
        已加入
      </v-chip>
      
      <v-btn
        color="error"
        variant="flat"
        size="small"
        class="mr-2"
        @click="handleLeave"
      >
        <v-icon start size="small">mdi-exit-to-app</v-icon>
        離開
      </v-btn>
    </v-app-bar>
    
    <v-main class="game-main">
      <!-- Connecting state -->
      <div v-if="isConnecting" class="d-flex flex-column align-center justify-center fill-height">
        <v-progress-circular
          indeterminate
          color="primary"
          size="64"
          class="mb-4"
        />
        <div class="text-h6 text-medium-emphasis">連接中...</div>
      </div>
      
      <!-- Error state -->
      <div v-else-if="lastError" class="d-flex flex-column align-center justify-center fill-height pa-4">
        <v-alert
          type="error"
          variant="tonal"
          class="mb-4"
          width="100%"
          max-width="600"
        >
          <v-alert-title>連接失敗</v-alert-title>
          {{ lastError }}
        </v-alert>
        <v-btn
          color="primary"
          variant="flat"
          @click="router.push({ name: 'connect' })"
        >
          <v-icon start>mdi-arrow-left</v-icon>
          返回連接頁面
        </v-btn>
      </div>
      
      <!-- Connected but not joined -->
      <div v-else-if="isConnected && !isJoined" class="d-flex flex-column align-center justify-center fill-height">
        <v-progress-circular
          indeterminate
          color="primary"
          size="64"
          class="mb-4"
        />
        <div class="text-h6 text-medium-emphasis">加入遊戲中...</div>
      </div>
      
      <!-- Game ready -->
      <div
        v-else-if="isJoined"
        ref="gameRef"
        class="phaser-game"
      />
      
      <!-- Fallback: not connected -->
      <div v-else class="d-flex flex-column align-center justify-center fill-height">
        <v-progress-circular
          indeterminate
          color="primary"
          size="64"
          class="mb-4"
        />
        <div class="text-h6 text-medium-emphasis">準備連接...</div>
      </div>
    </v-main>
  </v-app>
</template>

<style scoped>
.game-main {
  padding: 0 !important;
  overflow: hidden;
  background: #f5f5f5;
  height: 100%;
}

.phaser-game {
  width: 100%;
  height: 100%;
  display: flex;
  align-items: center;
  justify-content: center;
  overflow: hidden;
}

.fill-height {
  height: 100%;
}
</style>
