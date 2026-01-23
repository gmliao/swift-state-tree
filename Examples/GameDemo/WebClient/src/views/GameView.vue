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
      <div class="hud-scrim hud-scrim-top" aria-hidden="true"></div>
      <div class="hud-scrim hud-scrim-bottom" aria-hidden="true"></div>
      <div class="hud-status-badge glass-card" aria-live="polite">
        <div class="d-flex align-center gap-2">
          <div
            class="status-indicator"
            :class="isConnected ? 'bg-success' : 'bg-error'"
          ></div>
          <span class="text-caption font-weight-bold text-uppercase tracking-wide"
            >{{ isConnected ? "Connected" : "Offline" }}</span
          >
        </div>
        <v-btn
          class="hud-leave-btn"
          size="x-small"
          rounded="lg"
          @click="handleLeave"
          elevation="0"
          variant="text"
        >
          <v-icon start size="small">mdi-logout-variant</v-icon>
          Leave
        </v-btn>
      </div>

      <!-- Game controls overlay - Compact Skill Bar -->
      <div class="overlay-bottom">
        <div class="controls-panel glass-card elevation-0">
          <div class="skill-bar">
            <!-- Resource Display -->
            <div class="skill-bar-stats">
              <div class="stat-compact">
                <span class="text-body-2 font-weight-bold text-primary">{{
                  currentResources
                }}</span>
                <span class="text-caption text-secondary ml-1">資源</span>
              </div>
              <div class="stat-compact">
                <span class="text-body-2 font-weight-bold"
                  >Rank {{ weaponLevel }}</span
                >
              </div>
            </div>

            <!-- Skill Buttons -->
            <div class="skill-bar-actions">
              <v-btn
                class="skill-button btn-apple"
                @click="handleUpgradeWeapon"
                :disabled="currentResources < 5"
                rounded="lg"
                elevation="0"
              >
                <v-icon size="24">mdi-sword-cross</v-icon>
                <span class="skill-button-key">Q</span>
                <v-tooltip activator="parent" location="top"
                  >升級武器 (5)</v-tooltip
                >
              </v-btn>

              <v-btn
                class="skill-button btn-soft"
                @click="handleUpgradeTurret"
                :disabled="currentResources < 10"
                rounded="lg"
                elevation="0"
              >
                <v-icon size="24">mdi-tower-fire</v-icon>
                <span class="skill-button-key">W</span>
                <v-tooltip activator="parent" location="top"
                  >升級砲塔 (10)</v-tooltip
                >
              </v-btn>

              <v-btn
                :class="
                  turretPlacementMode
                    ? 'skill-button btn-apple'
                    : 'skill-button btn-soft'
                "
                @click="toggleTurretPlacement"
                :disabled="currentResources < 15"
                rounded="lg"
                elevation="0"
                :color="turretPlacementMode ? 'error' : 'primary'"
              >
                <v-icon size="24">{{
                  turretPlacementMode ? "mdi-close" : "mdi-plus"
                }}</v-icon>
                <span class="skill-button-key">T</span>
                <v-tooltip activator="parent" location="top">
                  {{ turretPlacementMode ? "取消放置" : "放置砲塔 (15)" }}
                </v-tooltip>
              </v-btn>
            </div>
          </div>
        </div>
      </div>

      <!-- Controls hint -->
      <div class="overlay-hint">
        <div class="hint-text glass-card hud-hint">
          <span class="text-caption font-weight-bold text-primary mr-2"
            >Controls</span
          >
          <span class="text-caption text-secondary"
            >Left Click: Move • Auto-Shoot Active • T: Place Turret</span
          >
        </div>
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

.hud-scrim {
  position: absolute;
  left: 0;
  right: 0;
  pointer-events: none;
}

.hud-scrim-top {
  top: 0;
  height: 120px;
  background: linear-gradient(
    to bottom,
    rgba(255, 255, 255, 0.85),
    rgba(255, 255, 255, 0)
  );
}

.hud-scrim-bottom {
  bottom: 0;
  height: 160px;
  background: linear-gradient(
    to top,
    rgba(255, 255, 255, 0.9),
    rgba(255, 255, 255, 0)
  );
}

.game-overlay .glass-card {
  background: rgba(248, 249, 252, 0.98);
  border: 1px solid rgba(0, 0, 0, 0.12) !important;
  box-shadow: 0 12px 28px rgba(0, 0, 0, 0.14);
}

.hud-status-badge {
  position: absolute;
  top: 14px;
  right: 16px;
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 6px 8px 6px 10px;
  border-radius: 999px;
  pointer-events: auto;
}

.hud-status-badge .text-caption {
  color: var(--color-text);
}

.hint-text {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 6px 10px;
  border-radius: 999px;
}

.hud-leave-btn {
  color: #b4232c !important;
  background: rgba(255, 59, 48, 0.12) !important;
  border: 1px solid rgba(255, 59, 48, 0.2) !important;
  font-weight: 600 !important;
  text-transform: none !important;
  letter-spacing: normal !important;
}

.hud-hint {
  color: var(--color-text);
}

.status-indicator {
  width: 8px;
  height: 8px;
  border-radius: 50%;
}

.overlay-bottom {
  position: absolute;
  bottom: 16px;
  left: 0;
  right: 0;
  z-index: 1000;
  pointer-events: none;
  display: flex;
  justify-content: center;
}

.controls-panel {
  padding: 12px 16px;
  pointer-events: auto;
  width: auto;
  max-width: 600px;
  margin: 0 24px;
}


.skill-bar {
  display: flex;
  align-items: center;
  gap: 16px;
}

.skill-bar-stats {
  display: flex;
  align-items: center;
  gap: 12px;
  margin-right: 16px;
  padding-right: 16px;
  border-right: 1px solid rgba(0, 0, 0, 0.1);
}

.stat-compact {
  display: flex;
  align-items: baseline;
  white-space: nowrap;
}

.skill-bar-actions {
  display: flex;
  gap: 8px;
}

.skill-button {
  width: 48px;
  height: 48px;
  min-width: 48px !important;
  padding: 0 !important;
  position: relative;
}

.skill-button-key {
  position: absolute;
  bottom: 2px;
  right: 2px;
  font-size: 10px;
  background: rgba(0, 0, 0, 0.3);
  color: white;
  padding: 2px 4px;
  border-radius: 4px;
  font-weight: 600;
  line-height: 1;
}

.overlay-hint {
  position: absolute;
  top: 14px;
  left: 16px;
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

@media (max-width: 960px) {
  .overlay-hint {
    left: 16px;
    right: 16px;
    top: 72px;
  }

  .controls-panel {
    margin: 0 12px;
    padding: 10px 12px;
    max-width: 100%;
  }

  .skill-bar {
    flex-wrap: wrap;
    justify-content: center;
  }

  .skill-bar-stats {
    width: 100%;
    justify-content: space-between;
    margin-right: 0;
    padding-right: 0;
    border-right: none;
    border-bottom: 1px solid rgba(0, 0, 0, 0.08);
    padding-bottom: 8px;
  }

  .skill-bar-actions {
    width: 100%;
    justify-content: center;
    flex-wrap: wrap;
  }
}

@media (max-width: 600px) {
  .overlay-bottom {
    bottom: 8px;
  }

  .skill-button {
    width: 44px;
    height: 44px;
    min-width: 44px !important;
  }

  .overlay-hint {
    display: none;
  }
}

@media (max-height: 600px) {
  .hud-scrim-top {
    height: 90px;
  }

  .hud-scrim-bottom {
    height: 200px;
  }
}
</style>
