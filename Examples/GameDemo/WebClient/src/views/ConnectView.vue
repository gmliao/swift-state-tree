<script setup lang="ts">
import { ref, onMounted } from "vue";
import { useRouter } from "vue-router";
import { useGameClient } from "../utils/gameClient";
import "@/styles/ui-tokens.css";

const router = useRouter();
const { connect, isConnecting, lastError } = useGameClient();

// Generate random user name: user-[五位數字]
function generateRandomUserName(): string {
  const randomNum = Math.floor(Math.random() * 100000)
    .toString()
    .padStart(5, "0");
  return `user-${randomNum}`;
}

const wsUrl = ref("ws://localhost:8080/game/hero-defense");
const playerName = ref("");
const roomId = ref("default");

// Auto-generate player name on mount
onMounted(() => {
  if (!playerName.value) {
    playerName.value = generateRandomUserName();
  }
});

async function handleConnect() {
  if (isConnecting.value) return;

  // Validate inputs
  if (!wsUrl.value.trim()) {
    return;
  }

  if (!playerName.value.trim()) {
    return;
  }

  try {
    // Connect to server
    await connect({
      wsUrl: wsUrl.value.trim(),
      playerName: playerName.value.trim(),
      landID: roomId.value.trim() || undefined,
    });

    // Store connection info in sessionStorage for reference
    sessionStorage.setItem("wsUrl", wsUrl.value.trim());
    sessionStorage.setItem("playerName", playerName.value.trim());
    sessionStorage.setItem("roomId", roomId.value.trim());
    sessionStorage.removeItem("replayMode");

    // Navigate to game view only after successful connection
    await router.push({ name: "game" });
  } catch (err) {
    // Error is already stored in lastError by useGameClient
  }
}

function goToReevaluationMonitor() {
  router.push({ name: "reevaluation-monitor" });
}
</script>

<template>
  <v-container
    fluid
    class="connect-bg connect-container fill-height d-flex align-center justify-center"
  >
    <v-card class="glass-card main-card pa-10">
      <div class="text-center mb-10">
        <h1
          class="text-h4 font-weight-bold mb-2 color-primary tracking-tight connect-title"
        >
          Hero Defense
        </h1>
        <p class="text-body-1 text-secondary font-weight-regular connect-subtitle">
          Battle for the High Ground
        </p>
      </div>

      <v-form @submit.prevent="handleConnect" class="connect-form">
        <div class="input-section mb-8">
          <label
            class="text-caption font-weight-semibold text-secondary mb-2 d-block ml-1"
            >Server Config</label
          >
          <v-text-field
            v-model="wsUrl"
            placeholder="ws://localhost:8080/game/hero-defense"
            variant="solo"
            flat
            density="comfortable"
            class="apple-input mb-5"
            prepend-inner-icon="mdi-server"
            rounded="lg"
            bg-color="rgba(0,0,0,0.03)"
          ></v-text-field>

          <label
            class="text-caption font-weight-semibold text-secondary mb-2 d-block ml-1"
            >Pilot Identity</label
          >
          <v-text-field
            v-model="playerName"
            placeholder="Enter Hero Name"
            variant="solo"
            flat
            density="comfortable"
            class="apple-input"
            prepend-inner-icon="mdi-account-circle-outline"
            rounded="lg"
            bg-color="rgba(0,0,0,0.03)"
          ></v-text-field>
        </div>

        <v-alert
          v-if="lastError"
          type="error"
          variant="tonal"
          class="mb-6 rounded-lg border-error"
          density="compact"
          icon="mdi-alert-circle-outline"
        >
          {{ lastError }}
        </v-alert>

        <v-btn
          type="submit"
          class="btn-apple mb-3"
          block
          size="large"
          elevation="0"
          :loading="isConnecting"
          rounded="lg"
          height="48"
        >
          <v-icon start class="mr-2">mdi-sword-cross</v-icon>
          Join Game
        </v-btn>

        <v-btn
          @click="goToReevaluationMonitor"
          class="btn-soft text-secondary"
          block
          size="large"
          variant="text"
          elevation="0"
          rounded="lg"
          height="48"
        >
          <v-icon start class="mr-2">mdi-chart-timeline-variant</v-icon>
          Reevaluation
        </v-btn>
      </v-form>

      <div class="text-center mt-8">
        <p class="text-caption text-tertiary">SwiftStateTree Protocol v1.4.2</p>
      </div>
    </v-card>
  </v-container>
</template>

<style scoped>
.connect-bg {
  background: var(--color-bg);
  background-image:
    radial-gradient(at 50% 0%, rgba(0, 122, 255, 0.08) 0px, transparent 50%),
    radial-gradient(at 50% 100%, rgba(52, 199, 89, 0.08) 0px, transparent 50%);
}

.connect-container {
  min-height: 100vh;
  padding: 24px !important;
  padding-block: 24px !important;
}

.main-card {
  box-shadow: 0 20px 40px rgba(0, 0, 0, 0.04) !important;
  border: 1px solid rgba(0, 0, 0, 0.03) !important;
  width: min(440px, 92vw);
}

.color-primary {
  color: var(--color-primary);
}

.text-tertiary {
  color: var(--color-secondary);
  opacity: 0.6;
}

.tracking-tight {
  letter-spacing: -0.02em;
}

.apple-input :deep(.v-field) {
  border: 1px solid transparent;
  transition: all 0.2s ease;
}

.apple-input :deep(.v-field--focused) {
  background: white !important;
  border-color: var(--color-primary);
  box-shadow: 0 0 0 4px rgba(0, 122, 255, 0.1);
}

@media (max-width: 600px) {
  .connect-container {
    align-items: flex-start !important;
    padding-block: 32px !important;
  }

  .main-card {
    padding: 24px !important;
  }
}

@media (max-height: 700px) {
  .connect-container {
    align-items: flex-start !important;
    padding-block: 24px !important;
  }

  .main-card {
    padding: 22px !important;
  }

  .connect-title {
    font-size: 1.45rem !important;
  }

  .connect-subtitle {
    font-size: 0.95rem !important;
  }
}

@media (max-height: 600px) {
  .connect-container {
    padding-block: 18px !important;
  }

  .main-card {
    padding: 18px !important;
  }

  .connect-title {
    font-size: 1.3rem !important;
  }

  .connect-subtitle {
    font-size: 0.9rem !important;
  }
}
</style>
