<script setup lang="ts">
import { ref, onMounted, onUnmounted, watch } from "vue";
import { useRouter } from "vue-router";
import Phaser from "phaser";
import { GameScene } from "../scenes/GameScene";
import { useGameClient } from "../utils/gameClient";

const router = useRouter();
const gameRef = ref<HTMLDivElement | null>(null);
const phaserGame = ref<Phaser.Game | null>(null);
const { isConnected, isJoined, disconnect, play, moveTo, tree, currentPlayerID } = useGameClient();

// Watch for disconnection and automatically redirect to connect page
// Watch isJoined: when it changes from true to false, we've been disconnected
watch(isJoined, (joined, wasJoined) => {
  // If we were joined but now not joined (disconnected), redirect to connect page
  if (wasJoined && !joined) {
    console.warn('⚠️ Server disconnected, redirecting to connect page')
    // disconnect() has already been called by the callback, just handle UI cleanup and navigation
    handleDisconnectUI()
  }
}, { immediate: false })

onMounted(async () => {
  // Check if already connected and joined
  if (!isJoined.value) {
    // If not connected, redirect to connect page
    router.push({ name: "connect" });
    return;
  }

  // Initialize Phaser game
  if (gameRef.value && tree.value) {
    // Get available space from the container element
    const containerRect = gameRef.value.getBoundingClientRect();

    phaserGame.value = new Phaser.Game({
      type: Phaser.AUTO,
      width: containerRect.width || 800,
      height: containerRect.height || 600,
      parent: gameRef.value,
      backgroundColor: "#ffffff",
      scene: [GameScene],
      physics: {
        default: "arcade",
        arcade: {
          gravity: { x: 0, y: 0 },
          debug: false,
        },
      },
      scale: {
        mode: Phaser.Scale.RESIZE,
        autoCenter: Phaser.Scale.CENTER_BOTH,
      },
    });

    // Wait for scene to be fully initialized, then set game client
    await new Promise((resolve) => setTimeout(resolve, 100));

    // Pass tree, play function, events, and current player ID to scene
    const scene = phaserGame.value.scene.getScene("GameScene") as GameScene;
    if (scene && tree.value) {
      scene.setGameClient({ 
        tree: tree.value, 
        play,
        events: {
          moveTo
        },
        currentPlayerID: currentPlayerID.value
      });
    }
  }
});

onUnmounted(async () => {
  if (phaserGame.value) {
    phaserGame.value.destroy(true);
    phaserGame.value = null;
  }
  await disconnect();
});

async function handleDisconnectUI() {
  // Clean up Phaser game
  if (phaserGame.value) {
    phaserGame.value.destroy(true);
    phaserGame.value = null;
  }
  
  // Clear session storage
  sessionStorage.removeItem("wsUrl");
  sessionStorage.removeItem("playerName");
  sessionStorage.removeItem("roomId");
  
  // Navigate back to connect page
  router.push({ name: "connect" });
}

async function handleDisconnect() {
  // Clean up Phaser game
  if (phaserGame.value) {
    phaserGame.value.destroy(true);
    phaserGame.value = null;
  }
  
  // Disconnect from server
  await disconnect();
  
  // Clear session storage
  sessionStorage.removeItem("wsUrl");
  sessionStorage.removeItem("playerName");
  sessionStorage.removeItem("roomId");
  
  // Navigate back to connect page
  router.push({ name: "connect" });
}

async function handleLeave() {
  await handleDisconnect();
}
</script>

<template>
  <v-main class="game-main" style="height: 100vh; overflow: hidden; padding: 0;">
    <!-- Floating UI overlay -->
    <div v-if="isJoined" class="game-overlay">
      <div class="overlay-top">
        <v-chip
          :color="isConnected ? 'success' : 'error'"
          variant="flat"
          size="small"
          class="mr-2"
        >
          {{ isConnected ? "已連接" : "未連接" }}
        </v-chip>
        <v-chip v-if="isJoined" color="info" variant="flat" size="small" class="mr-2">
          已加入
        </v-chip>
        <v-btn
          color="error"
          variant="flat"
          size="small"
          @click="handleLeave"
        >
          <v-icon start size="small">mdi-exit-to-app</v-icon>
          離開
        </v-btn>
      </div>
    </div>

    <!-- Game ready -->
    <div v-if="isJoined" ref="gameRef" class="phaser-game" />

    <!-- Not joined - redirect to connect -->
    <div
      v-else
      class="d-flex flex-column align-center justify-center fill-height"
    >
      <v-progress-circular
        indeterminate
        color="primary"
        size="64"
        class="mb-4"
      />
      <div class="text-h6 text-medium-emphasis">準備中...</div>
    </div>
  </v-main>
</template>

<style scoped>
.game-main {
  padding: 0 !important;
  overflow: hidden;
  background: #f5f5f5;
  position: relative;
}

.phaser-game {
  width: 100%;
  height: 100%;
  display: flex;
  align-items: center;
  justify-content: center;
  overflow: hidden;
}

.game-overlay {
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  z-index: 1000;
  pointer-events: none;
}

.overlay-top {
  display: flex;
  align-items: center;
  justify-content: flex-end;
  padding: 12px 16px;
  pointer-events: auto;
}

.fill-height {
  height: 100%;
}
</style>
