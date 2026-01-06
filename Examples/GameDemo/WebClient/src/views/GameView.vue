<script setup lang="ts">
import { ref, onMounted, onUnmounted } from "vue";
import { useRouter } from "vue-router";
import Phaser from "phaser";
import { GameScene } from "../scenes/GameScene";
import { useGameClient } from "../utils/gameClient";

const router = useRouter();
const gameRef = ref<HTMLDivElement | null>(null);
const phaserGame = ref<Phaser.Game | null>(null);
const { isConnected, isJoined, disconnect, play, tree } = useGameClient();

onMounted(async () => {
  // Check if already connected and joined
  if (!isJoined.value) {
    // If not connected, redirect to connect page
    router.push({ name: "connect" });
    return;
  }

  // Initialize Phaser game
  if (gameRef.value && tree.value) {
    // Get available space (viewport width and height minus toolbar)
    const availableWidth = Math.min(window.innerWidth, 1280);
    const availableHeight = Math.min(window.innerHeight - 64, 720);

    phaserGame.value = new Phaser.Game({
      type: Phaser.AUTO,
      width: availableWidth,
      height: availableHeight,
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
        mode: Phaser.Scale.FIT,
        autoCenter: Phaser.Scale.CENTER_BOTH,
      },
    });

    // Wait for scene to be fully initialized, then set game client
    await new Promise((resolve) => setTimeout(resolve, 100));

    // Pass tree and play function to scene (direct access to underlying state)
    const scene = phaserGame.value.scene.getScene("GameScene") as GameScene;
    if (scene && tree.value) {
      scene.setGameClient({ tree: tree.value, play });
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

async function handleLeave() {
  // Disconnect before leaving
  await disconnect();
  // Clear session storage
  sessionStorage.removeItem("wsUrl");
  sessionStorage.removeItem("playerName");
  sessionStorage.removeItem("roomId");
  // Navigate back to connect page
  router.push({ name: "connect" });
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
        {{ isConnected ? "已連接" : "未連接" }}
      </v-chip>

      <v-chip v-if="isJoined" color="info" variant="flat" class="mr-2">
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
