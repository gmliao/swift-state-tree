<template>
  <v-container fluid class="apple-dashboard pa-6">
    <v-row>
      <!-- Left sidebar: Record list -->
      <v-col cols="12" md="3">
        <v-card class="glass-card full-height-card px-2 d-flex flex-column">
          <v-card-title class="d-flex align-center pt-6 pb-4 flex-shrink-0">
            <v-btn
              icon="mdi-chevron-left"
              variant="text"
              @click="goBack"
              class="mr-2"
              color="primary"
            />
            <span class="text-h6 font-weight-bold ml-1">記錄列表</span>
          </v-card-title>

          <v-divider class="mx-4 mb-4" color="rgba(0,0,0,0.05)"></v-divider>

          <v-card-text
            class="pa-0 d-flex flex-column flex-grow-1"
            style="overflow: hidden; min-height: 0"
          >
            <div class="flex-grow-1 overflow-y-auto px-2">
              <v-list v-if="recordItems.length > 0" bg-color="transparent">
                <v-list-item
                  v-for="item in recordItems"
                  :key="item.record"
                  @click="selectRecord(item.record)"
                  :active="selectedRecord === item.record"
                  class="record-item mb-2 rounded-xl"
                  :variant="selectedRecord === item.record ? 'flat' : 'text'"
                  :color="selectedRecord === item.record ? 'primary' : ''"
                >
                  <v-list-item-title
                    class="record-title-row text-body-2 font-weight-semibold"
                    :title="item.display.tooltip"
                  >
                    <v-chip
                      v-if="item.display.badge"
                      size="x-small"
                      color="secondary"
                      variant="tonal"
                      class="record-badge"
                    >
                      {{ item.display.badge }}
                    </v-chip>
                    <span class="record-name">{{ item.display.title }}</span>
                  </v-list-item-title>
                </v-list-item>
              </v-list>

              <div v-else class="pa-4 text-center">
                <v-alert
                  type="info"
                  variant="text"
                  density="compact"
                  class="text-body-2 text-secondary"
                >
                  沒有可用的 record
                </v-alert>
              </div>
            </div>

            <v-divider color="rgba(0,0,0,0.05)"></v-divider>

            <div class="pa-4 flex-shrink-0">
              <v-btn
                v-if="!isVerifying"
                class="btn-apple monitor-action-btn"
                @click="startVerification"
                block
                rounded="xl"
                size="large"
                elevation="0"
                :disabled="!selectedRecord"
              >
                <v-icon start>mdi-play</v-icon>
                Start Verification
              </v-btn>

              <v-btn
                v-else
                class="btn-soft text-error monitor-action-btn"
                block
                rounded="xl"
                size="large"
                elevation="0"
                disabled
              >
                <v-icon start>mdi-progress-clock</v-icon>
                Verifying...
              </v-btn>

              <v-btn
                class="btn-soft monitor-action-btn mt-2"
                @click="startReplay"
                block
                rounded="xl"
                size="large"
                elevation="0"
                :loading="isStartingReplay"
                :disabled="!selectedRecord || isVerifying || isConnectingGame"
              >
                <v-icon start>mdi-play-network</v-icon>
                Start Replay Stream
              </v-btn>
            </div>
          </v-card-text>
        </v-card>
      </v-col>

      <!-- Right side: Verification results -->
      <v-col cols="12" md="9">
        <!-- Dashboard Header / Progress -->
        <v-card
          v-if="isVerifying || monitorState?.status === 'completed'"
          class="glass-card mb-6 pa-2 elevation-0"
        >
          <div class="d-flex align-center gap-6 pa-6">
            <v-btn
              v-if="isVerifying"
              :icon="monitorState?.isPaused ? 'mdi-play' : 'mdi-pause'"
              @click="togglePause"
              class="btn-apple"
              size="large"
              elevation="0"
            />

            <div class="flex-grow-1">
              <div class="d-flex justify-space-between align-end mb-3">
                <div>
                  <div
                    class="text-caption text-secondary font-weight-semibold text-uppercase tracking-wide"
                  >
                    Progress
                  </div>
                  <div class="text-h4 font-weight-bold mt-1">
                    {{ monitorState?.processedTicks || 0 }}
                    <span class="text-h6 text-secondary font-weight-regular"
                      >/ {{ monitorState?.totalTicks || 0 }}</span
                    >
                  </div>
                </div>
                <div class="text-right">
                  <div
                    class="text-caption text-secondary font-weight-semibold text-uppercase tracking-wide"
                  >
                    Accuracy
                  </div>
                  <div class="text-h4 font-weight-bold text-primary mt-1">
                    {{ progress.toFixed(1) }}%
                  </div>
                </div>
              </div>
              <v-progress-linear
                :model-value="progress"
                height="8"
                color="primary"
                bg-color="#E5E5EA"
                bg-opacity="1"
                rounded="pill"
                class="apple-progress"
              />
              <div class="progress-stats mt-4">
                <div class="progress-stat">
                  <div
                    class="text-caption text-secondary font-weight-bold text-uppercase tracking-wide"
                  >
                    Total Ticks
                  </div>
                  <div class="text-h6 font-weight-bold">
                    {{ monitorState?.totalTicks }}
                  </div>
                </div>
                <div class="progress-stat">
                  <div
                    class="text-caption text-success font-weight-bold text-uppercase tracking-wide"
                  >
                    Correct
                  </div>
                  <div class="text-h6 font-weight-bold text-success">
                    {{ monitorState?.correctTicks }}
                  </div>
                </div>
                <div class="progress-stat">
                  <div
                    class="text-caption text-error font-weight-bold text-uppercase tracking-wide"
                  >
                    Mismatches
                  </div>
                  <div class="text-h6 font-weight-bold text-error">
                    {{ monitorState?.mismatchedTicks }}
                  </div>
                </div>
              </div>
            </div>
          </div>
        </v-card>

        <v-row>
          <v-col :cols="showTickList ? 8 : 12">
            <!-- State tree view wrapper -->
            <v-card
              class="glass-card pa-0 overflow-hidden elevation-0"
              min-height="600"
            >
              <StateTreeDiffView
                v-if="monitorState?.currentTickId"
                :tick-id="monitorState.currentTickId"
                :expected-state="monitorState.currentExpectedState"
                :actual-state="monitorState.currentActualState"
                :is-match="monitorState.currentIsMatch"
              />
              <div
                v-else
                class="fill-height d-flex flex-column align-center justify-center text-secondary"
              >
                <v-icon size="64" color="secondary" class="mb-4 opacity-50"
                  >mdi-chart-box-outline</v-icon
                >
                <div class="text-h6 font-weight-medium opacity-70">
                  Waiting for selection
                </div>
              </div>
            </v-card>
          </v-col>

          <v-col v-if="showTickList" cols="4">
            <v-card class="glass-card tick-list-container pa-0 elevation-0">
              <v-card-title
                class="text-subtitle-1 py-4 px-5 d-flex align-center font-weight-bold"
              >
                <v-icon start color="primary" size="small" class="mr-2"
                  >mdi-history</v-icon
                >
                <span>History</span>
                <v-spacer />
                <v-chip
                  size="x-small"
                  color="secondary"
                  variant="flat"
                  class="font-weight-bold px-3"
                >
                  {{ tickResults.length }}
                </v-chip>
              </v-card-title>

              <v-divider color="rgba(0,0,0,0.05)"></v-divider>

              <div class="virtual-scroll-wrapper">
                <v-virtual-scroll
                  :items="tickResults"
                  height="552"
                  item-height="52"
                >
                  <template v-slot:default="{ item }">
                    <div
                      class="tick-item d-flex align-center px-5 py-3"
                      :class="{ 'mismatch-item': !item.isMatch }"
                      @click="showTickDetail(item)"
                    >
                      <div
                        class="tick-indicator mr-3"
                        :class="item.isMatch ? 'bg-success' : 'bg-error'"
                      ></div>

                      <div class="flex-grow-1">
                        <div class="text-body-2 font-weight-semibold">
                          Tick #{{ item.tickId }}
                        </div>
                        <div
                          class="text-caption text-secondary"
                          style="font-size: 11px"
                        >
                          {{ item.isMatch ? "Verified" : "Mismatch Found" }}
                        </div>
                      </div>

                      <v-icon size="small" color="secondary" class="opacity-50"
                        >mdi-chevron-right</v-icon
                      >
                    </div>
                  </template>
                </v-virtual-scroll>
              </div>
            </v-card>
          </v-col>
        </v-row>

        <!-- Error Alert -->
        <v-alert
          v-if="monitorState?.status === 'failed'"
          class="glass-card border-error mt-6"
          icon="mdi-alert-circle-outline"
          title="驗證失敗"
          :text="monitorState.errorMessage || 'Unknown error'"
          variant="tonal"
          color="error"
        ></v-alert>
      </v-col>
    </v-row>
  </v-container>
</template>

<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted } from "vue";
import { useRouter } from "vue-router";
import { LandClient } from "@/utils/LandClient";
import { useGameClient } from "@/utils/gameClient";
import StateTreeDiffView from "../components/StateTreeDiffView.vue";
import "@/styles/ui-tokens.css";

const router = useRouter();
const { connect: connectGame, isConnecting: isConnectingGame } = useGameClient();
const adminBaseURL = "http://localhost:8080";
const adminAPIKey = "hero-defense-admin-key";

const records = ref<string[]>([]);
const selectedRecord = ref<string | null>(null);
const isVerifying = ref(false);
const isStartingReplay = ref(false);
const monitorClient = ref<LandClient | null>(null);
const monitorState = ref<any>(null);
const tickResults = ref<any[]>([]);
const showTickList = ref(true);

const progress = computed(() => {
  if (!monitorState.value || monitorState.value.totalTicks === 0) return 0;
  return (
    (monitorState.value.processedTicks / monitorState.value.totalTicks) * 100
  );
});

type RecordDisplay = {
  title: string;
  badge?: string;
  tooltip: string;
};

const recordItems = computed(() =>
  records.value.map((record) => ({
    record,
    display: getRecordDisplay(record),
  }))
);

function getRecordName(path: string) {
  return path.split("/").pop() || path;
}

function getRecordDisplay(path: string): RecordDisplay {
  const fileName = getRecordName(path);
  const baseName = fileName.replace(/\.json$/i, "");
  const match = baseName.match(
    /^(.+)-(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}Z)-([A-Za-z0-9]+)$/
  );
  if (!match) {
    return {
      title: baseName,
      tooltip: fileName,
    };
  }

  const [, landType, timestamp] = match;
  return {
    title: formatRecordTimestamp(timestamp),
    badge: `(${formatLandType(landType)})`,
    tooltip: fileName,
  };
}

function formatLandType(landType: string) {
  return landType.replace(/defense$/i, "defences");
}

function formatRecordTimestamp(timestamp: string) {
  const [datePart, timePartWithZone] = timestamp.split("T");
  if (!timePartWithZone) return timestamp;
  const timePart = timePartWithZone.replace("Z", "");
  const normalizedTime = timePart.replace(/-/g, ":");
  return `${datePart} ${normalizedTime}Z`;
}

function selectRecord(record: string) {
  selectedRecord.value = record;
}

function goBack() {
  router.push({ name: "connect" });
}

function showTickDetail(tick: any) {
  console.log("Show tick detail:", tick);
}

async function loadRecords() {
  try {
    const response = await fetch(`${adminBaseURL}/admin/reevaluation/records`, {
      headers: {
        "X-API-Key": adminAPIKey,
      },
    });
    const data = await response.json();
    records.value = data.data || [];
  } catch (error) {
    console.error("Failed to load records:", error);
  }
}

async function startVerification() {
  if (!selectedRecord.value) return;

  if (monitorClient.value) {
    monitorClient.value.disconnect();
    monitorClient.value = null;
  }

  isVerifying.value = true;
  tickResults.value = []; // Clear previous results
  monitorState.value = null;

  try {
    const response = await fetch(`${adminBaseURL}/admin/reevaluation/start`, {
      method: "POST",
      headers: {
        "X-API-Key": adminAPIKey,
      },
    });
    const data = await response.json();
    const monitorLandID = data.data.monitorLandID;

    const wsUrl = "ws://localhost:8080/reevaluation-monitor";
    monitorClient.value = new LandClient(wsUrl, monitorLandID);

    await monitorClient.value.connect();

    monitorClient.value.onStateUpdate((state) => {
      monitorState.value = state;
      if (state.status === "completed" || state.status === "failed") {
        isVerifying.value = false;
      }
    });

    monitorClient.value.onEvent("TickSummary", (payload) => {
      tickResults.value.push(payload);
    });

    await monitorClient.value.sendAction("StartVerification", {
      landType: "hero-defense",
      recordFilePath: selectedRecord.value,
    });
  } catch (error) {
    console.error("Verification failed:", error);
    isVerifying.value = false;
  }
}

async function startReplay() {
  if (!selectedRecord.value || isStartingReplay.value || isConnectingGame.value) {
    return;
  }

  isStartingReplay.value = true;
  try {
    const replayResponse = await fetch(
      `${adminBaseURL}/admin/reevaluation/replay/start`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-API-Key": adminAPIKey,
        },
        body: JSON.stringify({
          landType: "hero-defense",
          recordFilePath: selectedRecord.value,
        }),
      },
    );

    if (!replayResponse.ok) {
      throw new Error(`Replay start failed: HTTP ${replayResponse.status}`);
    }

    const replayPayload = await replayResponse.json();
    const replayLandID = replayPayload?.data?.replayLandID as string | undefined;
    const webSocketPath = replayPayload?.data?.webSocketPath as string | undefined;
    if (!replayLandID || !webSocketPath) {
      throw new Error("Replay start response missing replayLandID or webSocketPath");
    }

    const replayWsUrl = `${adminBaseURL.replace(/^http/, "ws")}${webSocketPath}`;

    await connectGame({
      wsUrl: replayWsUrl,
      playerName: "replay-viewer",
      landID: replayLandID,
    });

    sessionStorage.setItem("wsUrl", replayWsUrl);
    sessionStorage.setItem("playerName", "replay-viewer");
    sessionStorage.setItem("roomId", replayLandID);
    sessionStorage.setItem("replayMode", "1");

    await router.push({ name: "game", query: { mode: "replay" } });
  } catch (error) {
    console.error("Start replay failed:", error);
  } finally {
    isStartingReplay.value = false;
  }
}

async function togglePause() {
  if (!monitorClient.value) return;

  const isPaused = monitorState.value?.isPaused;
  if (isPaused) {
    await monitorClient.value.sendAction("ResumeVerification", {});
  } else {
    await monitorClient.value.sendAction("PauseVerification", {});
  }
}

onMounted(() => {
  loadRecords();
});

onUnmounted(() => {
  if (monitorClient.value) {
    monitorClient.value.disconnect();
  }
});
</script>

<style scoped>
.apple-dashboard {
  background: var(--color-bg);
  min-height: 100vh;
}

.progress-stats {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 12px;
}

.progress-stat {
  display: flex;
  flex-direction: column;
  gap: 4px;
}

.full-height-card {
  height: calc(100vh - 64px);
}

.record-title-row {
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  gap: 4px;
}

.record-name {
  flex: 1 1 auto;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-size: 0.85rem;
}

.record-badge {
  font-size: 0.7rem;
  font-weight: 600;
  letter-spacing: 0.01em;
  background: rgba(52, 120, 246, 0.12) !important;
  border: 1px solid rgba(52, 120, 246, 0.2);
}

.record-item {
  transition: var(--transition-fast);
  cursor: pointer;
  padding: 8px 12px;
}

.record-item:hover:not(.v-list-item--active) {
  background: rgba(0, 0, 0, 0.03);
}

.apple-progress {
  background: rgba(0, 0, 0, 0.05) !important;
}

.tick-list-container {
  height: 600px;
}

.tick-item {
  cursor: pointer;
  transition: var(--transition-fast);
  border-bottom: 1px solid rgba(0, 0, 0, 0.02);
}

.tick-item:hover {
  background: rgba(0, 0, 0, 0.02);
}

.tick-indicator {
  width: 4px;
  height: 24px;
  border-radius: 4px;
}

.mismatch-item {
  background: rgba(255, 59, 48, 0.03);
}

.monitor-action-btn {
  font-size: 0.9rem;
  height: 40px !important;
}

@media (max-width: 960px) {
  .full-height-card {
    height: auto;
    min-height: 40vh;
  }

  .tick-list-container {
    height: 360px;
  }
}

@media (max-width: 600px) {
  .tick-list-container {
    height: 300px;
  }
}
</style>
