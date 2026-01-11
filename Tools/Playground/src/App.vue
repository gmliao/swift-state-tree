<template>
  <v-app>
    <v-app-bar color="blue-darken-2" prominent>
      <v-app-bar-title style="font-size: 1.5rem;">
        <span class="mr-2">🌲</span>
        SwiftStateTree Playground
      </v-app-bar-title>
      <v-spacer></v-spacer>
      <v-chip :color="connectionStatus.color" variant="flat" class="mr-2">
        <v-icon :icon="connectionStatus.icon" class="mr-1"></v-icon>
        {{ connectionStatus.text }}
      </v-chip>
      <v-chip
        v-if="isJoined && currentLandID"
        color="info"
        variant="flat"
        size="small"
        class="mr-2"
      >
        <v-icon icon="mdi-map-marker" size="small" class="mr-1"></v-icon>
        Land: {{ currentLandID }}
      </v-chip>
      <v-chip
        v-if="isJoined && currentPlayerID"
        color="secondary"
        variant="flat"
        size="small"
        class="mr-2"
      >
        <v-icon icon="mdi-account" size="small" class="mr-1"></v-icon>
        Player: {{ currentPlayerID }}
      </v-chip>
      <v-btn
        v-if="isConnected"
        color="error"
        variant="flat"
        size="small"
        class="mr-2"
        @click="handleDisconnect"
      >
        <v-icon icon="mdi-link-off" class="mr-1"></v-icon>
        斷線
      </v-btn>
      <v-btn
        :color="showLogPanel ? 'primary' : 'white'"
        :variant="showLogPanel ? 'flat' : 'outlined'"
        size="small"
        class="mr-4"
        @click="showLogPanel = !showLogPanel"
        :title="showLogPanel ? '隱藏日誌面板' : '顯示日誌面板'"
      >
        <v-icon :icon="showLogPanel ? 'mdi-eye-off' : 'mdi-eye'" class="mr-1"></v-icon>
        {{ showLogPanel ? '隱藏日誌' : '顯示日誌' }}
      </v-btn>
    </v-app-bar>

    <v-main style="height: calc(100vh - 64px); overflow: hidden;">
      <v-container fluid class="app-shell" :class="{ 'app-shell-scroll': !isConnected || !isJoined }">
        <!-- Connection Error Alert (shown at top when error exists) -->
        <v-row v-if="connectionError" justify="center" class="mb-2">
          <v-col cols="12" md="8" lg="6">
            <v-alert
              type="error"
              variant="tonal"
              prominent
              closable
              @click:close="connectionError = null"
            >
              <v-alert-title>連線錯誤</v-alert-title>
              {{ connectionError }}
            </v-alert>
          </v-col>
        </v-row>

        <!-- Connection State: Schema & Connection Setup -->
        <div v-if="!isConnected || !isJoined">
          <v-row justify="center">
            <v-col cols="12" md="8" lg="6">
              <v-card class="mb-4">
                <v-card-title>
                  <v-icon icon="mdi-file-upload" class="mr-2"></v-icon>
                  Schema 設定
                </v-card-title>
                <v-card-text>
                  <v-tabs v-model="schemaTab" class="mb-4">
                    <v-tab value="server">從伺服器</v-tab>
                    <v-tab value="file">上傳檔案</v-tab>
                  </v-tabs>
                  
                  <v-window v-model="schemaTab">
                    <v-window-item value="server">
                      <v-text-field
                        v-model="schemaUrl"
                        label="Schema URL"
                        prepend-icon="mdi-link"
                        variant="outlined"
                        hint="例如: http://localhost:8080/schema"
                        persistent-hint
                        class="mb-2"
                        style="margin-top: 8px;"
                      ></v-text-field>
                      
                      <v-btn
                        color="blue-darken-2"
                        block
                        @click="loadSchemaFromServer"
                        :loading="loadingSchema"
                        :disabled="!schemaUrl"
                      >
                        <v-icon icon="mdi-download" class="mr-2"></v-icon>
                        從伺服器載入
                      </v-btn>
                    </v-window-item>
                    
                    <v-window-item value="file">
                      <v-file-input
                        :model-value="schemaFile"
                        @update:model-value="handleFileChange"
                        label="上傳 JSON Schema"
                        accept=".json"
                        prepend-icon="mdi-file-code"
                        variant="outlined"
                        density="compact"
                      ></v-file-input>
                      
                      <v-btn
                        color="blue-darken-2"
                        block
                        class="mt-4"
                        @click="parseSchema"
                        :disabled="!schemaJson"
                      >
                        <v-icon icon="mdi-check" class="mr-2"></v-icon>
                        解析 Schema
                      </v-btn>
                    </v-window-item>
                  </v-window>

                  <v-alert
                    v-if="schemaError"
                    type="error"
                    density="compact"
                    class="mt-2"
                  >
                    {{ schemaError }}
                  </v-alert>
                  
                  <v-alert
                    v-if="schemaSuccess"
                    type="success"
                    density="compact"
                    class="mt-2"
                  >
                    Schema 載入成功
                  </v-alert>
                  
                  <!-- Land Selection (when multiple lands available) -->
                  <v-select
                    v-if="parsedSchema && availableLands.length > 1"
                    v-model="selectedLandID"
                    :items="availableLands"
                    label="選擇 Land"
                    prepend-icon="mdi-map-marker"
                    variant="outlined"
                    class="mt-4"
                    :disabled="isConnected || isJoined"
                    :hint="isConnected || isJoined ? '請先斷線後再更改 Land 選擇' : '此伺服器支援多個遊戲，請選擇要使用的 Land'"
                    persistent-hint
                  >
                    <template v-slot:item="{ props, item }">
                      <v-list-item v-bind="props">
                        <template v-slot:prepend>
                          <v-icon icon="mdi-gamepad-variant" class="mr-2"></v-icon>
                        </template>
                        <v-list-item-title>{{ item.raw.title }}</v-list-item-title>
                        <v-list-item-subtitle v-if="item.raw.subtitle">{{ item.raw.subtitle }}</v-list-item-subtitle>
                      </v-list-item>
                    </template>
                  </v-select>
                  
                  <v-alert
                    v-if="parsedSchema && availableLands.length > 1 && !selectedLandID"
                    type="info"
                    density="compact"
                    class="mt-2"
                  >
                    請選擇一個 Land 以繼續
                  </v-alert>
                  
                  <!-- Room Instance ID Input -->
                  <v-text-field
                    v-if="parsedSchema && selectedLandID"
                    v-model="landInstanceId"
                    label="房間編號 (Room Instance ID)"
                    prepend-icon="mdi-door"
                    variant="outlined"
                    class="mt-4"
                    :disabled="isConnected || isJoined"
                    hint="留空以讓伺服器自動分配房間，或輸入 'default' 以加入預設房間，或輸入特定房間編號以加入該房間"
                    persistent-hint
                  ></v-text-field>
                </v-card-text>
              </v-card>

              <v-card>
                <v-card-title>
                  <v-icon icon="mdi-web" class="mr-2"></v-icon>
                  連線設定
                </v-card-title>
                <v-card-text>
                  <v-text-field
                    v-model="wsUrl"
                    label="WebSocket URL"
                    prepend-icon="mdi-link"
                    variant="outlined"
                    class="mb-2"
                  ></v-text-field>
                  
                  <v-btn
                    color="primary"
                    block
                    class="mb-2"
                    @click="showJWTDialog = true"
                  >
                    <v-icon icon="mdi-key-variant" class="mr-2"></v-icon>
                    JWT 認證設定
                    <v-chip
                      v-if="jwtToken"
                      color="success"
                      size="small"
                      class="ml-2"
                    >
                      已設定
                    </v-chip>
                  </v-btn>
                  
                  <v-btn
                    color="success"
                    block
                    class="mb-2"
                    @click="connect"
                    :disabled="!wsUrl || isConnected || !parsedSchema || Boolean(parsedSchema && availableLands.length > 1 && (!selectedLandID || selectedLandID === ''))"
                  >
                    <v-icon icon="mdi-link" class="mr-2"></v-icon>
                    連線
                  </v-btn>
                  
                  <v-btn
                    color="error"
                    block
                    @click="disconnect"
                    :disabled="!isConnected"
                  >
                    <v-icon icon="mdi-link-off" class="mr-2"></v-icon>
                    斷線
                  </v-btn>
                  
                  <v-alert
                    v-if="connectionError"
                    type="error"
                    density="compact"
                    class="mt-2"
                    closable
                    @click:close="() => { connectionError = null }"
                  >
                    {{ connectionError }}
                  </v-alert>
                </v-card-text>
              </v-card>
            </v-col>
          </v-row>
        </div>

        <!-- Testing State: Full Playground -->
        <div v-else class="playground-layout">
          <div class="playground-main">
            <!-- Mobile/Tablet: Use tabs -->
            <div class="playground-mobile">
              <v-tabs v-model="tab" color="primary" class="playground-tabs">
                <v-tab value="state">
                  <v-icon icon="mdi-file-tree" size="small" class="mr-1"></v-icon>
                  狀態樹
                </v-tab>
                <v-tab value="actions">
                  <v-icon icon="mdi-lightning-bolt" size="small" class="mr-1"></v-icon>
                  Actions
                </v-tab>
                <v-tab value="events">
                  <v-icon icon="mdi-broadcast" size="small" class="mr-1"></v-icon>
                  Events
                </v-tab>
                <v-tab value="statistics">
                  <v-icon icon="mdi-chart-line" size="small" class="mr-1"></v-icon>
                  流量統計
                </v-tab>
              </v-tabs>
              
              <v-window v-model="tab" class="playground-window">
                <v-window-item value="state" class="playground-window-item">
                  <div class="state-tree-container-mobile">
                    <div class="state-tree-header" style="padding: 8px; border-bottom: 1px solid rgba(0,0,0,0.12); display: flex; align-items: center;">
                      <v-icon icon="mdi-file-tree" size="small" class="mr-1"></v-icon>
                      <span>狀態樹</span>
                      <v-spacer></v-spacer>
                      <v-select
                        v-model="stateTreeUpdateSpeed"
                        :items="[
                          { title: '即時', value: 'realtime' },
                          { title: '每秒', value: 'throttled' }
                        ]"
                        density="compact"
                        variant="outlined"
                        hide-details
                        style="max-width: 100px; margin-right: 8px;"
                      ></v-select>
                      <v-btn-toggle
                        v-model="stateTreeViewMode"
                        mandatory
                        density="compact"
                        variant="outlined"
                        size="small"
                        style="margin-right: 8px;"
                      >
                        <v-btn value="tree">
                          <v-icon icon="mdi-file-tree" size="small" class="mr-1"></v-icon>
                          樹狀
                        </v-btn>
                        <v-btn value="json">
                          <v-icon icon="mdi-code-json" size="small" class="mr-1"></v-icon>
                          JSON
                        </v-btn>
                      </v-btn-toggle>
                      <v-btn
                        v-if="stateTreeViewMode === 'json'"
                        icon="mdi-content-copy"
                        size="small"
                        variant="text"
                        density="compact"
                        style="margin-right: 8px;"
                        @click="copyStateJson"
                        :title="copyJsonButtonText"
                      ></v-btn>
                    </div>
                    <div class="state-tree-content">
                      <StateTreeViewer
                        :state="throttledState"
                        :schema="parsedSchema"
                        :view-mode="stateTreeViewMode"
                      />
                    </div>
                  </div>
                </v-window-item>
                
                <v-window-item value="actions" class="playground-window-item">
                  <div class="actions-events-container-mobile">
                    <ActionPanel
                      :schema="parsedSchema"
                      :connected="isConnected"
                      :selected-land-i-d="selectedLandID"
                      :action-results="actionResults"
                      @send-action="handleSendAction"
                    />
                  </div>
                </v-window-item>
                
                <v-window-item value="events" class="playground-window-item">
                  <div class="actions-events-container-mobile">
                    <EventPanel
                      :schema="parsedSchema"
                      :connected="isConnected"
                      :selected-land-i-d="selectedLandID"
                      @send-event="handleSendEvent"
                    />
                  </div>
                </v-window-item>

                <v-window-item value="statistics" class="playground-window-item">
                  <div class="actions-events-container-mobile">
                    <StatisticsPanel
                      :connected="isConnected"
                      :state-updates="stateUpdates"
                      :message-statistics="messageStatistics"
                    />
                  </div>
                </v-window-item>
              </v-window>
            </div>
            
            <!-- Desktop: Side by side -->
            <div class="playground-desktop">
              <v-row class="panel-row">
                <!-- Left Panel: State Tree -->
                <v-col cols="12" md="6" class="panel-col">
                  <div class="state-tree-container">
                    <div class="state-tree-header">
                      <v-icon icon="mdi-file-tree" size="small" class="mr-1"></v-icon>
                      <span>狀態樹</span>
                      <v-spacer></v-spacer>
                      <v-select
                        v-model="stateTreeUpdateSpeed"
                        :items="[
                          { title: '即時', value: 'realtime' },
                          { title: '每秒', value: 'throttled' }
                        ]"
                        density="compact"
                        variant="outlined"
                        hide-details
                        style="max-width: 100px; margin-right: 8px;"
                      ></v-select>
                      <v-btn-toggle
                        v-model="stateTreeViewMode"
                        mandatory
                        density="compact"
                        variant="outlined"
                        size="small"
                        style="margin-right: 8px;"
                      >
                        <v-btn value="tree">
                          <v-icon icon="mdi-file-tree" size="small" class="mr-1"></v-icon>
                          樹狀
                        </v-btn>
                        <v-btn value="json">
                          <v-icon icon="mdi-code-json" size="small" class="mr-1"></v-icon>
                          JSON
                        </v-btn>
                      </v-btn-toggle>
                      <v-btn
                        v-if="stateTreeViewMode === 'json'"
                        icon="mdi-content-copy"
                        size="small"
                        variant="text"
                        density="compact"
                        style="margin-right: 8px;"
                        @click="copyStateJson"
                        :title="copyJsonButtonText"
                      ></v-btn>
                    </div>
                    <div class="state-tree-content">
                      <StateTreeViewer
                        :state="throttledState"
                        :schema="parsedSchema"
                        :view-mode="stateTreeViewMode"
                      />
                    </div>
                  </div>
                </v-col>

                <!-- Right Panel: Actions & Events -->
                <v-col cols="12" md="6" class="panel-col">
                  <div class="actions-events-container">
                    <v-tabs v-model="tab" color="primary" class="actions-events-tabs">
                      <v-tab value="actions">
                        <v-icon icon="mdi-lightning-bolt" size="small" class="mr-1"></v-icon>
                        Actions
                      </v-tab>
                      <v-tab value="events">
                        <v-icon icon="mdi-broadcast" size="small" class="mr-1"></v-icon>
                        Events
                      </v-tab>
                      <v-tab value="statistics">
                        <v-icon icon="mdi-chart-line" size="small" class="mr-1"></v-icon>
                        流量統計
                      </v-tab>
                    </v-tabs>

                    <div class="actions-events-content">
                      <v-window v-model="tab" class="actions-events-window">
                        <v-window-item value="actions" class="actions-events-window-item">
                          <ActionPanel
                            :schema="parsedSchema"
                            :connected="isConnected"
                            :selected-land-i-d="selectedLandID"
                            :action-results="actionResults"
                            @send-action="handleSendAction"
                          />
                        </v-window-item>

                        <v-window-item value="events" class="actions-events-window-item">
                          <EventPanel
                            :schema="parsedSchema"
                            :connected="isConnected"
                            :selected-land-i-d="selectedLandID"
                            @send-event="handleSendEvent"
                          />
                        </v-window-item>

                        <v-window-item value="statistics" class="actions-events-window-item">
                          <StatisticsPanel
                            :connected="isConnected"
                            :state-updates="stateUpdates"
                            :message-statistics="messageStatistics"
                          />
                        </v-window-item>
                      </v-window>
                    </div>
                  </div>
                </v-col>
              </v-row>
            </div>
          </div>
          
          <!-- Bottom Panel: Logs & State Updates (Resizable) -->
          <div v-if="showLogPanel" class="log-panel-wrapper">
            <ResizableLogPanel
              :height="logPanelHeight"
              :logTab="logTab"
              :logs="logs"
              :stateUpdates="stateUpdates"
              @update:logTab="logTab = $event"
              @update:height="logPanelHeight = $event"
              @clear-logs="handleClearLogs"
              @clear-state-updates="handleClearStateUpdates"
            />
          </div>
        </div>
      </v-container>
    </v-main>

    <!-- JWT 設定 Dialog -->
    <v-dialog v-model="showJWTDialog" max-width="600">
      <v-card>
        <v-card-title>
          <v-icon icon="mdi-key-variant" class="mr-2"></v-icon>
          JWT 認證設定
        </v-card-title>
        <v-card-text>
          <v-text-field
            v-model="jwtSecretKey"
            label="JWT Secret Key"
            prepend-icon="mdi-key"
            variant="outlined"
            density="compact"
            type="password"
            hint="必須與伺服器配置的 JWT_SECRET_KEY 一致（預設: demo-secret-key-change-in-production）"
            persistent-hint
            class="mb-2"
          ></v-text-field>
          
          <v-text-field
            v-model="jwtPlayerID"
            label="Player ID *"
            prepend-icon="mdi-account"
            variant="outlined"
            density="compact"
            hint="JWT payload 中的 playerID（必填）"
            persistent-hint
            class="mb-2"
          ></v-text-field>
          
          <v-text-field
            v-model="jwtDeviceID"
            label="Device ID (可選)"
            prepend-icon="mdi-devices"
            variant="outlined"
            density="compact"
            class="mb-2"
          ></v-text-field>
          
          <v-text-field
            v-model="jwtUsername"
            label="Username (可選)"
            prepend-icon="mdi-account-circle"
            variant="outlined"
            density="compact"
            class="mb-2"
          ></v-text-field>
          
          <v-btn
            color="secondary"
            block
            class="mb-2"
            @click="autoFillJWTFields"
          >
            <v-icon icon="mdi-auto-fix" class="mr-2"></v-icon>
            自動填入測試資料
          </v-btn>
          
          <v-btn
            color="primary"
            block
            @click="generateToken"
            :disabled="!jwtSecretKey || !jwtPlayerID"
          >
            <v-icon icon="mdi-key-variant" class="mr-2"></v-icon>
            生成 JWT Token
          </v-btn>
          
          <v-alert
            v-if="jwtToken"
            type="success"
            density="compact"
            class="mt-2"
          >
            <div class="text-caption">Token 已生成（將在連接時使用）</div>
            <div class="text-caption font-mono" style="word-break: break-all; font-size: 0.7rem;">
              {{ jwtToken.substring(0, 50) }}...
            </div>
          </v-alert>
          
          <v-alert
            v-if="jwtError"
            type="error"
            density="compact"
            class="mt-2"
          >
            {{ jwtError }}
          </v-alert>
        </v-card-text>
        <v-card-actions>
          <v-spacer></v-spacer>
          <v-btn
            color="primary"
            @click="handleCloseJWTDialog"
          >
            關閉
          </v-btn>
        </v-card-actions>
      </v-card>
    </v-dialog>
  </v-app>
</template>

<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted, watch } from 'vue'
import StateTreeViewer from './components/StateTreeViewer.vue'
import ActionPanel from './components/ActionPanel.vue'
import EventPanel from './components/EventPanel.vue'
import StatisticsPanel from './components/StatisticsPanel.vue'
import ResizableLogPanel from './components/ResizableLogPanel.vue'
import { useWebSocket } from './composables/useWebSocket'
import { useSchema } from './composables/useSchema'
import { generateJWT } from './utils/jwt'
import { IVec2, Position2, Angle } from '@swiftstatetree/sdk/core'

const tab = ref('actions')
const logTab = ref('messages')
const logPanelHeight = ref(200)
const showLogPanel = ref(false) // Default: hidden
const stateTreeUpdateSpeed = ref<'realtime' | 'throttled'>('throttled')
const stateTreeViewMode = ref<'tree' | 'json'>('tree')
const copyJsonButtonText = ref('複製 JSON')
const schemaTab = ref('server')
const schemaFile = ref<File[] | null>(null)
const schemaJson = ref('')
const schemaUrl = ref('http://localhost:8080/schema')
const wsUrl = ref('ws://localhost:8080/game')
const loadingSchema = ref(false)
const schemaSuccess = ref(false)
const selectedLandID = ref<string>('')
const landInstanceId = ref<string>('default')
const actionResults = ref<Array<{
  actionName: string
  success: boolean
  response?: any
  error?: string
  timestamp: Date
}>>([])

// JWT Configuration (預設使用 demo 的 secret key)
const jwtSecretKey = ref('demo-secret-key-change-in-production')
const jwtPlayerID = ref('')
const jwtDeviceID = ref('')
const jwtUsername = ref('')
const jwtToken = ref('')
const jwtError = ref('')
const showJWTDialog = ref(false)

const { parsedSchema, error: schemaErrorFromComposable, parseSchema, loadSchema } = useSchema(schemaJson)
const localSchemaError = ref<string | null>(null)
const schemaError = computed(() => localSchemaError.value || schemaErrorFromComposable.value)

// Available lands from schema
const availableLands = computed(() => {
  if (!parsedSchema.value || !parsedSchema.value.lands) return []
  return Object.keys(parsedSchema.value.lands).map(landID => ({
    title: landID,
    value: landID,
    subtitle: parsedSchema.value?.lands[landID]?.stateType || ''
  }))
})

// Auto-select first land when schema loads
watch(parsedSchema, (newSchema) => {
  if (newSchema && availableLands.value.length > 0 && !selectedLandID.value) {
    selectedLandID.value = availableLands.value[0].value
  }
}, { immediate: true })

// Auto-update WebSocket URL when land is selected
watch(selectedLandID, (newLandID) => {
  if (!newLandID) return
  
  try {
    // Parse current WebSocket URL
    const url = new URL(wsUrl.value)
    
    // Extract base URL (protocol + host + port)
    const baseURL = `${url.protocol}//${url.host}`
    
    // Build new path based on current path structure
    let newPath: string
    const currentPath = url.pathname
    
    if (currentPath === '/' || currentPath === '') {
      // If path is root, use /game/{landID} format
      newPath = `/game/${newLandID}`
    } else if (currentPath === '/game' || currentPath.startsWith('/game/')) {
      // If path is /game or /game/..., replace with /game/{landID}
      newPath = `/game/${newLandID}`
    } else {
      // Otherwise, append /{landID} to current path
      newPath = `${currentPath.replace(/\/$/, '')}/${newLandID}`
    }
    
    // Preserve query parameters if any
    const query = url.search
    
    // Update WebSocket URL
    wsUrl.value = `${baseURL}${newPath}${query}`
  } catch (error) {
    // If URL parsing fails, try simple string replacement
    // This handles cases where wsUrl might not be a valid URL yet
    const baseMatch = wsUrl.value.match(/^(wss?:\/\/[^\/]+)/)
    if (baseMatch) {
      const baseURL = baseMatch[1]
      // Use /game/{landID} format as default
      wsUrl.value = `${baseURL}/game/${newLandID}`
    }
  }
})

const { 
  isConnected,
  isJoined,
  connectionError,
  currentState, 
  currentLandID,
  currentPlayerID,
  logs, 
  stateUpdates,
  messageStatistics,
  actionResults: actionResultsFromWS,
  connect: connectWebSocket, 
  disconnect, 
  sendAction, 
  sendEvent 
} = useWebSocket(wsUrl, parsedSchema, selectedLandID, landInstanceId, showLogPanel)

// Throttled state for StateTreeViewer (updates at most once per second)
const throttledState = ref<Record<string, any>>({})
let throttleTimer: number | null = null
let lastUpdateTime = 0

watch([currentState, stateTreeUpdateSpeed], ([newState, speed]) => {
  if (speed === 'realtime') {
    // Real-time: update immediately
    throttledState.value = newState
    if (throttleTimer) {
      clearTimeout(throttleTimer)
      throttleTimer = null
    }
  } else {
    // Throttled: update at most once per second
    const now = Date.now()
    if (now - lastUpdateTime >= 1000) {
      // More than 1 second has passed, update immediately
      throttledState.value = newState
      lastUpdateTime = now
    } else {
      // Schedule update for the next second boundary
      // Always update the pending state to use the latest value
      if (!throttleTimer) {
        const timeUntilNextSecond = 1000 - (now - lastUpdateTime)
        throttleTimer = window.setTimeout(() => {
          // Use currentState.value to get the latest state when timer fires
          throttledState.value = currentState.value
          lastUpdateTime = Date.now()
          throttleTimer = null
        }, timeUntilNextSecond)
      }
    }
  }
}, { immediate: true, deep: true })

// Cleanup on unmount
onUnmounted(() => {
  if (throttleTimer) {
    clearTimeout(throttleTimer)
    throttleTimer = null
  }
})

// Serialize state to JSON (handles DeterministicMath types)
const serializeStateForJson = (obj: any): any => {
  if (obj === null || obj === undefined) {
    return obj
  }
  
  // Handle DeterministicMath class instances
  if (obj instanceof IVec2) {
    return { x: obj.x, y: obj.y, rawX: obj.rawX, rawY: obj.rawY }
  }
  if (obj instanceof Position2) {
    return { v: serializeStateForJson(obj.v) }
  }
  if (obj instanceof Angle) {
    return { degrees: obj.degrees, rawDegrees: obj.rawDegrees }
  }
  
  // Handle arrays
  if (Array.isArray(obj)) {
    return obj.map(item => serializeStateForJson(item))
  }
  
  // Handle objects
  if (typeof obj === 'object') {
    const result: Record<string, any> = {}
    for (const [key, value] of Object.entries(obj)) {
      result[key] = serializeStateForJson(value)
    }
    return result
  }
  
  return obj
}

// Copy JSON to clipboard
const copyStateJson = async () => {
  try {
    if (!throttledState.value || Object.keys(throttledState.value).length === 0) {
      copyJsonButtonText.value = '無狀態可複製'
      setTimeout(() => {
        copyJsonButtonText.value = '複製 JSON'
      }, 2000)
      return
    }
    
    const serialized = serializeStateForJson(throttledState.value)
    const jsonString = JSON.stringify(serialized, null, 2)
    
    await navigator.clipboard.writeText(jsonString)
    copyJsonButtonText.value = '已複製！'
    setTimeout(() => {
      copyJsonButtonText.value = '複製 JSON'
    }, 2000)
  } catch (err) {
    console.error('Failed to copy JSON:', err)
    copyJsonButtonText.value = '複製失敗'
    setTimeout(() => {
      copyJsonButtonText.value = '複製 JSON'
    }, 2000)
  }
}

// Sync action results from WebSocket composable
watch(actionResultsFromWS, (newResults) => {
  actionResults.value = newResults
}, { deep: true })

const connect = () => {
  // If JWT token is available, append it to the WebSocket URL as query parameter
  // Note: Standard WebSocket API doesn't support custom headers, so we use query parameter
  // The server should extract token from query parameter if Authorization header is not present
  let url = wsUrl.value
  if (jwtToken.value) {
    const separator = url.includes('?') ? '&' : '?'
    url = `${url}${separator}token=${encodeURIComponent(jwtToken.value)}`
    console.log('🔑 Using JWT token for connection:', jwtToken.value.substring(0, 20) + '...')
  } else {
    console.log('👤 No JWT token - connecting as guest (server supports guest mode)')
  }
  console.log('🔌 Connecting to:', url)
  
  // Pass the URL with token directly to connectWebSocket
  connectWebSocket(url)
}

const connectionStatus = computed(() => {
  if (isConnected.value) {
    return { text: '已連線', color: 'success', icon: 'mdi-check-circle' }
  }
  return { text: '未連線', color: 'error', icon: 'mdi-close-circle' }
})

const handleFileChange = (files: File[] | File | null) => {
  if (!files) return

  const file = Array.isArray(files) ? files[0] : files
  if (!file) return

  schemaFile.value = Array.isArray(files) ? files : [file]
  loadSchema(file)
}

const handleSendAction = (actionName: string, payload: any, landID: string) => {
  sendAction(actionName, payload, landID)
}

const handleSendEvent = (eventName: string, payload: any, landID: string) => {
  sendEvent(eventName, payload, landID)
}

const handleDisconnect = () => {
  disconnect()
}

const handleClearLogs = () => {
  // Clear logs by resetting the logs array
  // Note: We need to access the logs from useWebSocket
  // Since logs is a ref from useWebSocket, we need to clear it there
  // For now, we'll emit an event or directly modify if possible
  if (logs.value) {
    logs.value.length = 0
  }
}

const handleClearStateUpdates = () => {
  // Clear state updates
  if (stateUpdates.value) {
    stateUpdates.value.length = 0
  }
}

const autoFillJWTFields = async () => {
  // 自動生成測試資料
  const randomID = () => Math.random().toString(36).substring(2, 10)
  const randomNum = (min: number, max: number) => Math.floor(Math.random() * (max - min + 1)) + min
  
  jwtPlayerID.value = `player-${randomID()}`
  jwtDeviceID.value = `device-${randomID()}`
  jwtUsername.value = `user${randomNum(1, 100)}`
  
  // 自動生成 token（如果必填欄位都有值）
  if (jwtSecretKey.value && jwtPlayerID.value) {
    await generateToken()
  }
}

const generateToken = async () => {
  jwtError.value = ''
  jwtToken.value = ''
  
  if (!jwtSecretKey.value) {
    jwtError.value = '請輸入 JWT Secret Key'
    return false
  }
  
  if (!jwtPlayerID.value) {
    jwtError.value = '請輸入 Player ID'
    return false
  }
  
  try {
    const payload: any = {
      playerID: jwtPlayerID.value
    }
    
    if (jwtDeviceID.value) payload.deviceID = jwtDeviceID.value
    if (jwtUsername.value) payload.username = jwtUsername.value
    
    jwtToken.value = await generateJWT(jwtSecretKey.value, payload)
    jwtError.value = ''
    return true
  } catch (err: any) {
    jwtError.value = `生成 Token 失敗: ${err.message || err}`
    return false
  }
}

const handleCloseJWTDialog = async () => {
  // 如果必填欄位都有值但還沒有 token，自動生成
  if (jwtSecretKey.value && jwtPlayerID.value && !jwtToken.value) {
    await generateToken()
  }
  showJWTDialog.value = false
}

const loadSchemaFromServer = async () => {
  if (!schemaUrl.value) return
  
  loadingSchema.value = true
  schemaSuccess.value = false
  localSchemaError.value = null
  
  try {
    const response = await fetch(schemaUrl.value)
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}: ${response.statusText}`)
    }
    const json = await response.json()
    schemaJson.value = JSON.stringify(json, null, 2)
    parseSchema()
    schemaSuccess.value = true
    localSchemaError.value = null
  } catch (err: any) {
    localSchemaError.value = `載入失敗: ${err.message || err}`
    schemaSuccess.value = false
  } finally {
    loadingSchema.value = false
  }
}

onMounted(() => {
  // Auto-load schema from server if URL is provided
  if (schemaTab.value === 'server' && schemaUrl.value) {
    loadSchemaFromServer()
  } else if (schemaJson.value) {
    parseSchema()
  }
})
</script>

<style>
.v-application {
  background: #f5f5f5;
  min-height: 100vh;
}

.app-shell {
  height: 100%;
  max-height: calc(100vh - 64px);
  padding: 8px;
  display: flex;
  flex-direction: column;
  gap: 12px;
  overflow: hidden;
}

.app-shell-scroll {
  overflow: auto;
}

.playground-layout {
  display: grid;
  grid-template-rows: 1fr auto;
  flex: 1;
  min-height: 0;
  gap: 12px;
  height: 100%;
}

.playground-main {
  flex: 1;
  min-height: 0;
  display: flex;
  flex-direction: column;
  overflow: hidden;
}

/* Mobile/Tablet: Show tabs, hide side-by-side */
.playground-mobile {
  display: flex;
  flex-direction: column;
  height: 100%;
  overflow: hidden;
}

.playground-desktop {
  display: none;
}

.playground-tabs {
  flex-shrink: 0;
  border-bottom: 1px solid rgba(var(--v-border-color), var(--v-border-opacity));
}

.playground-tabs .v-tab {
  font-size: 0.875rem;
  min-height: 48px;
}

.playground-window {
  flex: 1;
  min-height: 0;
  display: flex;
  flex-direction: column;
  height: 100%;
}

.playground-window-item {
  flex: 1;
  min-height: 0;
  overflow: auto;
  height: 100%;
}

.state-tree-container-mobile,
.actions-events-container-mobile {
  height: 100%;
  display: flex;
  flex-direction: column;
  overflow: hidden;
}

.state-tree-container-mobile .state-tree-content {
  flex: 1;
  min-height: 0;
  overflow: auto;
  padding: 8px;
}

.actions-events-container-mobile {
  flex: 1;
  min-height: 0;
  overflow: hidden;
  display: flex;
  flex-direction: column;
}

.actions-events-container-mobile .action-panel,
.actions-events-container-mobile .event-panel,
.actions-events-container-mobile .statistics-panel {
  flex: 1;
  min-height: 0;
  overflow: auto;
  height: 100%;
}

/* Desktop: Show side-by-side, hide tabs */
@media (min-width: 960px) {
  .playground-mobile {
    display: none;
  }
  
  .playground-desktop {
    display: flex;
    flex-direction: column;
    height: 100%;
    overflow: hidden;
  }
  
  .panel-row {
    flex: 1;
    min-height: 0;
    margin: 0;
    height: 100%;
  }
}

.panel-col {
  display: flex;
  flex-direction: column;
  padding: 8px;
  min-height: 0;
  height: 100%;
}


.log-panel-wrapper {
  flex-shrink: 0;
}

.scroll-area {
  flex: 1;
  min-height: 0;
  overflow: auto;
  height: 100%;
  max-height: 100%;
}

.state-tree-container {
  display: flex;
  flex-direction: column;
  height: 100%;
  min-height: 0;
  border: 1px solid rgba(var(--v-border-color), var(--v-border-opacity));
  border-radius: 4px;
  background: rgb(var(--v-theme-surface));
}

.state-tree-header {
  display: flex;
  align-items: center;
  padding: 8px 16px;
  font-size: 0.875rem;
  font-weight: 500;
  border-bottom: 1px solid rgba(var(--v-border-color), var(--v-border-opacity));
  flex-shrink: 0;
  min-height: 48px;
}

.state-tree-content {
  flex: 1;
  min-height: 0;
  overflow: auto;
  padding: 8px;
}

.actions-events-container {
  display: flex;
  flex-direction: column;
  height: 100%;
  min-height: 0;
  border: 1px solid rgba(var(--v-border-color), var(--v-border-opacity));
  border-radius: 4px;
  background: rgb(var(--v-theme-surface));
}

.actions-events-tabs {
  flex-shrink: 0;
  border-bottom: 1px solid rgba(var(--v-border-color), var(--v-border-opacity));
}

.actions-events-tabs .v-tab {
  font-size: 0.875rem;
  min-height: 48px;
}

.actions-events-content {
  flex: 1;
  min-height: 0;
  overflow: hidden;
  display: flex;
  flex-direction: column;
}

.actions-events-window {
  flex: 1;
  min-height: 0;
  display: flex;
  flex-direction: column;
  overflow: hidden;
  height: 100%;
}

.actions-events-window-item {
  flex: 1;
  min-height: 0;
  overflow: hidden;
  padding: 0;
  display: flex;
  flex-direction: column;
  position: relative;
}

.actions-events-window .v-window__container {
  height: 100%;
}

.actions-events-window .v-window-item {
  height: 100%;
}

.actions-events-window-item .action-panel,
.actions-events-window-item .event-panel,
.actions-events-window-item .statistics-panel {
  flex: 1;
  min-height: 0;
  overflow-y: auto;
  overflow-x: hidden;
}
</style>
