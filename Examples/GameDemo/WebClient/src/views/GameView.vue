<script setup lang="ts">
import { ref, onMounted, onUnmounted, watch } from "vue";
import { useRouter } from "vue-router";
import Phaser from "phaser";
import { GameScene } from "../scenes/GameScene";
import { useGameClient } from "../utils/gameClient";

const router = useRouter();
const gameRef = ref<HTMLDivElement | null>(null);
const phaserGame = ref<Phaser.Game | null>(null);
const { isConnected, isJoined, disconnect, tree } = useGameClient();

// Game state for UI
const currentResources = ref(0);
const weaponLevel = ref(0);
const turretPlacementMode = ref(false);

// Watch game state for UI updates
watch(
  () => tree.value?.state,
  (state) => {
    if (state && tree.value?.currentPlayerID) {
      const player = (state as any).players?.[tree.value.currentPlayerID];
      if (player) {
        currentResources.value = player.resources || 0;
        weaponLevel.value = player.weaponLevel || 0;
      }
    }
  },
  { deep: true, immediate: true },
);

// Update turret placement mode periodically
let placementModeInterval: number | null = null;
watch(
  [phaserGame, tree],
  () => {
    if (placementModeInterval) {
      clearInterval(placementModeInterval);
    }

    if (phaserGame.value) {
      placementModeInterval = window.setInterval(() => {
        const scene = phaserGame.value?.scene.getScene(
          "GameScene",
        ) as GameScene;
        if (scene) {
          const inputHandler = scene.getPlaceTurretInput();
          turretPlacementMode.value =
            inputHandler?.isInPlacementMode() || false;
        }
      }, 100);
    }
  },
  { immediate: true },
);

onUnmounted(() => {
  if (placementModeInterval) {
    clearInterval(placementModeInterval);
  }
});

// Watch for disconnection and automatically redirect to connect page
// Watch isJoined: when it changes from true to false, we've been disconnected
watch(
  isJoined,
  (joined, wasJoined) => {
    // If we were joined but now not joined (disconnected), redirect to connect page
    if (wasJoined && !joined) {
      console.warn("⚠️ Server disconnected, redirecting to connect page");
      // disconnect() has already been called by the callback, just handle UI cleanup and navigation
      handleDisconnectUI();
    }
  },
  { immediate: false },
);

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

    // Pass tree to scene (tree.currentPlayerID is automatically available)
    const scene = phaserGame.value.scene.getScene("GameScene") as GameScene;
    if (scene && tree.value) {
      scene.setStateTree(tree.value);
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

async function handleUpgradeWeapon() {
  if (tree.value) {
    try {
      await tree.value.events.upgradeWeapon({});
      // console.log removed
    } catch (error) {
      console.error("Failed to upgrade weapon:", error);
    }
  }
}

async function handleUpgradeTurret() {
  if (tree.value && phaserGame.value) {
    const scene = phaserGame.value.scene.getScene("GameScene") as GameScene;
    if (!scene) return;

    // Get all turrets owned by current player
    const state = tree.value.state as any;
    const currentPlayerID = tree.value.currentPlayerID;
    if (!currentPlayerID || !state.turrets) return;

    const playerTurrets = Object.entries(state.turrets)
      .filter(
        ([_, turret]: [string, any]) => turret.ownerID === currentPlayerID,
      )
      .map(([idStr, turret]: [string, any]) => ({
        id: Number(idStr),
        level: turret.level || 0,
      }));

    if (playerTurrets.length === 0) {
      // console.log removed
      return;
    }

    // Find the turret with the lowest level
    const lowestLevelTurret = playerTurrets.reduce((min, turret) =>
      turret.level < min.level ? turret : min,
    );

    try {
      await tree.value.events.upgradeTurret({ turretID: lowestLevelTurret.id });
      // console.log removed
    } catch (error) {
      console.error("Failed to upgrade turret:", error);
    }
  }
}

function toggleTurretPlacement() {
  if (phaserGame.value) {
    const scene = phaserGame.value.scene.getScene("GameScene") as GameScene;
    if (scene) {
      const inputHandler = scene.getPlaceTurretInput();
      if (inputHandler) {
        // Toggle placement mode by simulating T key press
        const event = new KeyboardEvent("keydown", { key: "t", code: "KeyT" });
        scene.input.keyboard?.emit("keydown-T", event);
      }
    }
  }
}
</script>

<template>
  <v-main class="game-main">
    <!-- Floating UI overlay -->
    <div v-if="isJoined" class="game-overlay">
      <!-- Game controls overlay -->
      <div class="overlay-bottom">
        <div class="controls-panel glass-card elevation-0">
          <div
            class="controls-section d-flex align-center justify-space-between mb-4"
          >
            <div class="d-flex gap-8">
              <div class="stat-box">
                <div
                  class="text-caption text-secondary font-weight-semibold text-uppercase mb-1 tracking-wide"
                >
                  Resources
                </div>
                <div
                  class="text-h4 font-weight-bold text-primary tracking-tight"
                >
                  {{ currentResources }}
                </div>
              </div>
              <div class="stat-box">
                <div
                  class="text-caption text-secondary font-weight-semibold text-uppercase mb-1 tracking-wide"
                >
                  Weapon Rank
                </div>
                <div class="text-h4 font-weight-bold tracking-tight">
                  Rank {{ weaponLevel }}
                </div>
              </div>
            </div>
          </div>

          <v-divider class="mb-5" color="rgba(0,0,0,0.05)"></v-divider>

          <div class="controls-actions d-flex gap-4">
            <v-btn
              class="btn-apple flex-grow-1"
              @click="handleUpgradeWeapon"
              :disabled="currentResources < 5"
              rounded="lg"
              size="large"
              elevation="0"
              height="44"
            >
              <v-icon start size="small" class="mr-1">mdi-sword-cross</v-icon>
              Upgrade (5)
            </v-btn>

            <v-btn
              class="btn-soft flex-grow-1"
              @click="handleUpgradeTurret"
              :disabled="currentResources < 10"
              rounded="lg"
              size="large"
              elevation="0"
              height="44"
            >
              <v-icon start size="small" class="mr-1">mdi-tower-fire</v-icon>
              Turret (10)
            </v-btn>

            <v-btn
              :class="turretPlacementMode ? 'btn-apple' : 'btn-soft'"
              @click="toggleTurretPlacement"
              :disabled="currentResources < 15"
              rounded="lg"
              size="large"
              elevation="0"
              height="44"
              :color="turretPlacementMode ? 'error' : 'primary'"
            >
              <v-icon start size="small" class="mr-1">{{
                turretPlacementMode ? "mdi-close" : "mdi-plus"
              }}</v-icon>
              {{ turretPlacementMode ? "Cancel" : "Place (15)" }}
            </v-btn>
          </div>
        </div>
      </div>

      <!-- Controls hint -->
      <div class="overlay-hint">
        <div
          class="hint-text glass-card py-3 px-5 text-caption font-weight-medium elevation-0"
        >
          <span class="text-primary font-weight-bold mr-2">Controls</span>
          <span class="text-secondary"
            >Left Click: Move • Auto-Shoot Active • T: Place Turret</span
          >
        </div>
      </div>

      <!-- Connection status and leave button -->
      <div
        class="overlay-top glass-card mx-6 my-6 px-5 py-3 d-flex align-center elevation-0"
      >
        <div class="d-flex align-center gap-3">
          <div
            class="status-indicator"
            :class="isConnected ? 'bg-success' : 'bg-error'"
          ></div>
          <span
            class="text-caption font-weight-bold text-uppercase tracking-wide text-secondary"
            >{{ isConnected ? "Connected" : "Offline" }}</span
          >
        </div>
        <v-spacer />
        <v-btn
          class="btn-soft text-error px-4"
          size="small"
          rounded="lg"
          @click="handleLeave"
          elevation="0"
          variant="text"
        >
          <v-icon start size="small">mdi-logout-variant</v-icon>
          Leave
        </v-btn>
      </div>
    </div>

    <!-- Game ready -->
    <div v-if="isJoined" ref="gameRef" class="phaser-game" />

    <!-- Not joined - loading -->
    <div
      v-else
      class="apple-dashboard fill-height d-flex flex-column align-center justify-center"
    >
      <v-progress-circular
        indeterminate
        color="primary"
        size="48"
        width="4"
        class="mb-6"
      />
      <div class="text-h5 font-weight-bold mb-2 tracking-tight">
        Initializing...
      </div>
      <div class="text-body-2 text-secondary">Connecting to Battle Grid</div>
    </div>
  </v-main>
</template>

<style scoped>
.game-main {
  padding: 0 !important;
  overflow: hidden;
  background: var(--color-bg);
  position: relative;
  height: 100vh;
  width: 100%;
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
  bottom: 0;
  z-index: 1000;
  pointer-events: none;
}

.overlay-top {
  pointer-events: auto;
}

.status-indicator {
  width: 8px;
  height: 8px;
  border-radius: 50%;
}

.overlay-bottom {
  position: absolute;
  bottom: 40px;
  left: 0;
  right: 0;
  z-index: 1000;
  pointer-events: none;
  display: flex; /* Enable flex to center children */
  justify-content: center;
}

.controls-panel {
  padding: 24px 28px;
  pointer-events: auto;
  width: 100%;
  max-width: 860px; /* Constrain width for better proportions */
  margin: 0 24px; /* Ensure some margin on mobile */
}

.stat-box {
  min-width: 140px;
}

.overlay-hint {
  position: absolute;
  top: 100px;
  left: 40px;
  z-index: 1000;
  pointer-events: none;
}

.tracking-widest {
  letter-spacing: 0.1em;
}

.tracking-wide {
  letter-spacing: 0.05em;
}

.tracking-tight {
  letter-spacing: -0.01em;
}

.gap-3 {
  gap: 12px;
}
.gap-4 {
  gap: 16px;
}
.gap-6 {
  gap: 24px;
}
.gap-8 {
  gap: 32px;
}
</style>
