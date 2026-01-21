<template>
  <v-container fluid class="fill-height">
    <v-row class="fill-height">
      <!-- Left sidebar: Record list -->
      <v-col cols="12" md="3">
        <v-card>
          <v-card-title>
            <v-btn icon variant="text" @click="goBack" class="mr-2">
              <v-icon>mdi-arrow-left</v-icon>
            </v-btn>
            記錄列表
          </v-card-title>
          <v-card-text>
            <v-list v-if="records.length > 0">
              <v-list-item
                v-for="record in records"
                :key="record"
                @click="selectRecord(record)"
                :active="selectedRecord === record"
                class="mb-2"
              >
                <template v-slot:prepend>
                  <v-icon>mdi-file-document</v-icon>
                </template>
                <v-list-item-title>{{
                  getRecordName(record)
                }}</v-list-item-title>
              </v-list-item>
            </v-list>

            <v-alert v-else type="info" variant="tonal">
              沒有可用的 reevaluation 記錄
            </v-alert>

            <v-btn
              v-if="selectedRecord && !isVerifying"
              color="primary"
              @click="startVerification"
              block
              class="mt-4"
            >
              <v-icon start>mdi-play</v-icon>
              開始驗證
            </v-btn>
          </v-card-text>
        </v-card>
      </v-col>

      <!-- Right side: Verification results -->
      <v-col cols="12" md="9">
        <!-- Playback controls -->
        <v-card v-if="isVerifying" class="mb-4">
          <v-card-text>
            <div class="d-flex align-center gap-4">
              <v-btn
                :icon="monitorState?.isPaused ? 'mdi-play' : 'mdi-pause'"
                @click="togglePause"
                color="primary"
              />

              <div class="flex-grow-1">
                <div class="text-subtitle-2">
                  Tick {{ monitorState?.currentTickId || 0 }} /
                  {{ monitorState?.totalTicks || 0 }}
                </div>
                <v-progress-linear
                  :model-value="progress"
                  height="8"
                  color="primary"
                />
              </div>
            </div>
          </v-card-text>
        </v-card>

        <!-- State tree view -->
        <StateTreeDiffView
          v-if="monitorState?.currentTickId"
          :tick-id="monitorState.currentTickId"
          :expected-state="monitorState.currentExpectedState"
          :actual-state="monitorState.currentActualState"
          :is-match="monitorState.currentIsMatch"
        />

        <!-- Error Alert -->
        <v-alert
          v-if="monitorState?.status === 'failed'"
          type="error"
          title="驗證失敗"
          :text="monitorState.errorMessage || 'Unknown error'"
          class="mb-4"
        ></v-alert>

        <!-- Statistics -->
        <v-row
          v-if="
            monitorState?.status === 'completed' ||
            monitorState?.status === 'failed'
          "
          class="mt-4"
        >
          <v-col cols="4">
            <v-card>
              <v-card-text class="text-center">
                <div class="text-h3">{{ monitorState.totalTicks }}</div>
                <div class="text-subtitle-1">總 Ticks</div>
              </v-card-text>
            </v-card>
          </v-col>
          <v-col cols="4">
            <v-card color="success">
              <v-card-text class="text-center">
                <div class="text-h3">{{ monitorState.correctTicks }}</div>
                <div class="text-subtitle-1">正確</div>
              </v-card-text>
            </v-card>
          </v-col>
          <v-col cols="4">
            <v-card color="error">
              <v-card-text class="text-center">
                <div class="text-h3">{{ monitorState.mismatchedTicks }}</div>
                <div class="text-subtitle-1">錯誤</div>
              </v-card-text>
            </v-card>
          </v-col>
        </v-row>
      </v-col>
    </v-row>
  </v-container>
</template>

<script setup lang="ts">
import { ref, computed, onMounted } from "vue";
import { useRouter } from "vue-router";
import { LandClient } from "@/utils/LandClient";
import StateTreeDiffView from "../components/StateTreeDiffView.vue";

const router = useRouter();
const records = ref<string[]>([]);
const selectedRecord = ref<string | null>(null);
const isVerifying = ref(false);
const monitorClient = ref<LandClient | null>(null);
const monitorState = ref<any>(null);

const progress = computed(() => {
  if (!monitorState.value || monitorState.value.totalTicks === 0) return 0;
  return (
    (monitorState.value.processedTicks / monitorState.value.totalTicks) * 100
  );
});

function getRecordName(path: string) {
  return path.split("/").pop() || path;
}

function selectRecord(record: string) {
  selectedRecord.value = record;
}

function goBack() {
  router.push({ name: "connect" });
}

async function loadRecords() {
  try {
    const response = await fetch(
      "http://localhost:8080/admin/reevaluation/records",
      {
        headers: {
          "X-API-Key": "hero-defense-admin-key",
        },
      },
    );
    const data = await response.json();
    records.value = data.data || [];
  } catch (error) {
    console.error("Failed to load records:", error);
  }
}

async function startVerification() {
  if (!selectedRecord.value) return;

  isVerifying.value = true;

  try {
    // 1. Create monitor land
    const response = await fetch(
      "http://localhost:8080/admin/reevaluation/start",
      {
        method: "POST",
        headers: {
          "X-API-Key": "hero-defense-admin-key",
        },
      },
    );
    const data = await response.json();
    const monitorLandID = data.data.monitorLandID;

    // 2. Connect to monitor land
    const wsUrl = "ws://localhost:8080/reevaluation-monitor";
    monitorClient.value = new LandClient(wsUrl, monitorLandID);

    await monitorClient.value.connect();

    // 3. Listen to state updates
    monitorClient.value.onStateUpdate((state) => {
      monitorState.value = state;
      if (state.status === "completed" || state.status === "failed") {
        isVerifying.value = false;
      }
    });

    // 4. Send startVerification action
    await monitorClient.value.sendAction("StartVerification", {
      landType: "hero-defense",
      recordFilePath: selectedRecord.value,
    });
  } catch (error) {
    console.error("Verification failed:", error);
    isVerifying.value = false;
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
</script>

<style scoped>
.fill-height {
  height: 100vh;
}
</style>
