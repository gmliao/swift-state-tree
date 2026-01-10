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
watch(() => tree.value?.state, (state) => {
  if (state && tree.value?.currentPlayerID) {
    const player = (state as any).players?.[tree.value.currentPlayerID];
    if (player) {
      currentResources.value = player.resources || 0;
      weaponLevel.value = player.weaponLevel || 0;
    }
  }
}, { deep: true, immediate: true });

// Update turret placement mode periodically
let placementModeInterval: number | null = null;
watch([phaserGame, tree], () => {
  if (placementModeInterval) {
    clearInterval(placementModeInterval);
  }
  
  if (phaserGame.value) {
    placementModeInterval = window.setInterval(() => {
      const scene = phaserGame.value?.scene.getScene("GameScene") as GameScene;
      if (scene) {
        const inputHandler = scene.getPlaceTurretInput();
        turretPlacementMode.value = inputHandler?.isInPlacementMode() || false;
      }
    }, 100);
  }
}, { immediate: true });

onUnmounted(() => {
  if (placementModeInterval) {
    clearInterval(placementModeInterval);
  }
});

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
      console.log('UpgradeWeaponEvent sent');
    } catch (error) {
      console.error('Failed to upgrade weapon:', error);
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
      .filter(([_, turret]: [string, any]) => turret.ownerID === currentPlayerID)
      .map(([idStr, turret]: [string, any]) => ({ id: Number(idStr), level: turret.level || 0 }));
    
    if (playerTurrets.length === 0) {
      console.log('No turrets to upgrade');
      return;
    }
    
    // Find the turret with the lowest level
    const lowestLevelTurret = playerTurrets.reduce((min, turret) => 
      turret.level < min.level ? turret : min
    );
    
    try {
      await tree.value.events.upgradeTurret({ turretID: lowestLevelTurret.id });
      console.log('UpgradeTurretEvent sent for lowest level turret:', lowestLevelTurret.id, 'level:', lowestLevelTurret.level);
    } catch (error) {
      console.error('Failed to upgrade turret:', error);
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
        const event = new KeyboardEvent('keydown', { key: 't', code: 'KeyT' });
        scene.input.keyboard?.emit('keydown-T', event);
      }
    }
  }
}
</script>

<template>
  <v-main class="game-main" style="height: 100vh; overflow: hidden; padding: 0;">
    <!-- Floating UI overlay -->
    <div v-if="isJoined" class="game-overlay">
      <!-- Game controls overlay -->
      <div class="overlay-bottom">
        <div class="controls-panel">
          <div class="controls-section">
            <div class="control-label">資源: {{ currentResources }}</div>
            <div class="control-label">武器等級: {{ weaponLevel }}</div>
          </div>
          
          <div class="controls-section">
            <v-btn
              color="primary"
              variant="flat"
              size="small"
              @click="handleUpgradeWeapon"
              :disabled="currentResources < 5"
              class="mr-2"
            >
              <v-icon start size="small">mdi-sword</v-icon>
              升級武器 (5)
            </v-btn>
            
            <v-btn
              color="secondary"
              variant="flat"
              size="small"
              @click="handleUpgradeTurret"
              :disabled="currentResources < 10"
              class="mr-2"
            >
              <v-icon start size="small">mdi-tower-fire</v-icon>
              升級炮塔 (10)
            </v-btn>
            
            <v-btn
              :color="turretPlacementMode ? 'success' : 'default'"
              variant="flat"
              size="small"
              @click="toggleTurretPlacement"
              :disabled="currentResources < 15"
            >
              <v-icon start size="small">mdi-map-marker</v-icon>
              {{ turretPlacementMode ? '取消放置' : `放置炮塔 (15)` }}
            </v-btn>
          </div>
        </div>
      </div>
      
      <!-- Controls hint -->
      <div class="overlay-hint">
        <div class="hint-text">
          <div>左鍵: 移動 | 自動射擊已啟用 | T: 放置炮塔</div>
        </div>
      </div>
      
      <!-- Connection status and leave button (at top) -->
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
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  display: flex;
  align-items: center;
  justify-content: flex-start;
  padding: 12px 16px;
  pointer-events: auto;
  background: rgba(255, 255, 255, 0.95);
  border-bottom: 1px solid rgba(0, 0, 0, 0.1);
  z-index: 1001;
  min-height: 52px; /* 確保有足夠高度 */
  box-shadow: 0 2px 8px rgba(0, 0, 0, 0.1);
}

.overlay-bottom {
  position: absolute;
  bottom: 0;
  left: 0;
  right: 0;
  z-index: 1000;
  pointer-events: none;
  display: block; /* 確保顯示 */
}

.controls-panel {
  background: rgba(255, 255, 255, 0.95);
  border-radius: 8px 8px 0 0;
  padding: 12px 16px;
  margin: 0 16px;
  box-shadow: 0 -2px 8px rgba(0, 0, 0, 0.1);
  pointer-events: auto;
  margin-bottom: 0; /* 確保貼近底部 */
}

.controls-section {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-bottom: 8px;
}

.controls-section:last-child {
  margin-bottom: 0;
}

.control-label {
  font-size: 14px;
  font-weight: 500;
  color: #333;
  margin-right: 16px;
}

.overlay-hint {
  position: absolute;
  top: 60px;
  left: 16px;
  z-index: 1000;
  pointer-events: none;
}

.hint-text {
  background: rgba(0, 0, 0, 0.7);
  color: white;
  padding: 8px 12px;
  border-radius: 4px;
  font-size: 12px;
  font-family: monospace;
}

.fill-height {
  height: 100%;
}
</style>
