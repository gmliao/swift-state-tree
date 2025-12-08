<template>
  <v-app>
    <v-app-bar color="blue-darken-2" prominent>
      <v-app-bar-title>
        <v-icon icon="mdi-rocket-launch" class="mr-2"></v-icon>
        SwiftStateTree Playground
      </v-app-bar-title>
      <v-spacer></v-spacer>
      <v-chip :color="connectionStatus.color" variant="flat" class="mr-2">
        <v-icon :icon="connectionStatus.icon" class="mr-1"></v-icon>
        {{ connectionStatus.text }}
      </v-chip>
      <v-btn
        v-if="isConnected"
        color="error"
        variant="flat"
        size="small"
        class="mr-4"
        @click="handleDisconnect"
      >
        <v-icon icon="mdi-link-off" class="mr-1"></v-icon>
        斷線
      </v-btn>
    </v-app-bar>

    <v-main style="overflow: hidden; height: calc(100vh - 64px);">
      <v-container fluid style="height: 100%; padding: 8px; display: flex; flex-direction: column;">
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
                        density="compact"
                        hint="例如: http://localhost:8080/schema"
                        persistent-hint
                        class="mb-2"
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
                    density="compact"
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
                    :disabled="!wsUrl || isConnected"
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
                </v-card-text>
              </v-card>
            </v-col>
          </v-row>
        </div>

        <!-- Testing State: Full Playground -->
        <div v-else style="display: flex; flex-direction: column; flex: 1; min-height: 0;">
          <div style="flex: 1; min-height: 0; display: flex; flex-direction: column;">
            <v-row style="flex: 1; min-height: 0; margin: 0;">
              <!-- Left Panel: State Tree (Wider) -->
              <v-col cols="12" md="6" style="display: flex; flex-direction: column; padding: 8px;">
                <v-card style="flex: 1; display: flex; flex-direction: column; min-height: 0;">
                  <v-card-title>
                    <v-icon icon="mdi-file-tree" class="mr-2"></v-icon>
                    狀態樹
                  </v-card-title>
                  <v-card-text style="flex: 1; overflow: auto;">
                    <StateTreeViewer
                      :state="currentState"
                      :schema="parsedSchema"
                    />
                  </v-card-text>
                </v-card>
              </v-col>

              <!-- Middle Panel: Actions & Events -->
              <v-col cols="12" md="6" style="display: flex; flex-direction: column; padding: 8px;">
                <v-card style="flex: 1; display: flex; flex-direction: column; min-height: 0;">
                  <v-tabs v-model="tab" color="primary">
                    <v-tab value="actions">
                      <v-icon icon="mdi-lightning-bolt" class="mr-2"></v-icon>
                      Actions
                    </v-tab>
                    <v-tab value="events">
                      <v-icon icon="mdi-broadcast" class="mr-2"></v-icon>
                      Events
                    </v-tab>
                  </v-tabs>

                  <v-window v-model="tab" style="flex: 1; min-height: 0;">
                    <v-window-item value="actions" style="height: 100%; overflow: auto;">
                      <ActionPanel
                        :schema="parsedSchema"
                        :connected="isConnected"
                        @send-action="handleSendAction"
                      />
                    </v-window-item>

                    <v-window-item value="events" style="height: 100%; overflow: auto;">
                      <EventPanel
                        :schema="parsedSchema"
                        :connected="isConnected"
                        @send-event="handleSendEvent"
                      />
                    </v-window-item>
                  </v-window>
                </v-card>
              </v-col>
            </v-row>
          </div>
          
          <!-- Bottom Panel: Logs & State Updates (Resizable) -->
          <div style="flex-shrink: 0;">
            <ResizableLogPanel
              :height="logPanelHeight"
              :logTab="logTab"
              :logs="logs"
              :stateUpdates="stateUpdates"
              @update:logTab="logTab = $event"
              @update:height="logPanelHeight = $event"
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
          
          <v-text-field
            v-model="jwtSchoolID"
            label="School ID (可選)"
            prepend-icon="mdi-school"
            variant="outlined"
            density="compact"
            class="mb-2"
          ></v-text-field>
          
          <v-text-field
            v-model="jwtLevel"
            label="Level (可選)"
            prepend-icon="mdi-numeric"
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
            @click="showJWTDialog = false"
          >
            關閉
          </v-btn>
        </v-card-actions>
      </v-card>
    </v-dialog>
  </v-app>
</template>

<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import StateTreeViewer from './components/StateTreeViewer.vue'
import ActionPanel from './components/ActionPanel.vue'
import EventPanel from './components/EventPanel.vue'
import ResizableLogPanel from './components/ResizableLogPanel.vue'
import { useWebSocket } from './composables/useWebSocket'
import { useSchema } from './composables/useSchema'
import { generateJWT } from './utils/jwt'

const tab = ref('actions')
const logTab = ref('messages')
const logPanelHeight = ref(200)
const schemaTab = ref('server')
const schemaFile = ref<File[] | null>(null)
const schemaJson = ref('')
const schemaUrl = ref('http://localhost:8080/schema')
const wsUrl = ref('ws://localhost:8080/game')
const loadingSchema = ref(false)
const schemaSuccess = ref(false)

// JWT Configuration (預設使用 demo 的 secret key)
const jwtSecretKey = ref('demo-secret-key-change-in-production')
const jwtPlayerID = ref('')
const jwtDeviceID = ref('')
const jwtUsername = ref('')
const jwtSchoolID = ref('')
const jwtLevel = ref('')
const jwtToken = ref('')
const jwtError = ref('')
const showJWTDialog = ref(false)

const { parsedSchema, error: schemaErrorFromComposable, parseSchema, loadSchema } = useSchema(schemaJson)
const localSchemaError = ref<string | null>(null)
const schemaError = computed(() => localSchemaError.value || schemaErrorFromComposable.value)
const { 
  isConnected,
  isJoined,
  currentState, 
  logs, 
  stateUpdates,
  connect: connectWebSocket, 
  disconnect, 
  sendAction, 
  sendEvent 
} = useWebSocket(wsUrl, parsedSchema)

const connect = () => {
  // If JWT token is available, append it to the WebSocket URL as query parameter
  // Note: Standard WebSocket API doesn't support custom headers, so we use query parameter
  // The server should extract token from query parameter if Authorization header is not present
  let url = wsUrl.value
  if (jwtToken.value) {
    const separator = url.includes('?') ? '&' : '?'
    url = `${url}${separator}token=${encodeURIComponent(jwtToken.value)}`
  }
  
  // Temporarily update wsUrl to include token
  const originalUrl = wsUrl.value
  wsUrl.value = url
  connectWebSocket()
  // Restore original URL after connection attempt
  wsUrl.value = originalUrl
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

const autoFillJWTFields = () => {
  // 自動生成測試資料
  const randomID = () => Math.random().toString(36).substring(2, 10)
  const randomNum = (min: number, max: number) => Math.floor(Math.random() * (max - min + 1)) + min
  
  jwtPlayerID.value = `player-${randomID()}`
  jwtDeviceID.value = `device-${randomID()}`
  jwtUsername.value = `user${randomNum(1, 100)}`
  jwtSchoolID.value = `school-${randomNum(1000, 9999)}`
  jwtLevel.value = String(randomNum(1, 50))
}

const generateToken = async () => {
  jwtError.value = ''
  jwtToken.value = ''
  
  if (!jwtSecretKey.value) {
    jwtError.value = '請輸入 JWT Secret Key'
    return
  }
  
  if (!jwtPlayerID.value) {
    jwtError.value = '請輸入 Player ID'
    return
  }
  
  try {
    const payload: any = {
      playerID: jwtPlayerID.value
    }
    
    if (jwtDeviceID.value) payload.deviceID = jwtDeviceID.value
    if (jwtUsername.value) payload.username = jwtUsername.value
    if (jwtSchoolID.value) payload.schoolid = jwtSchoolID.value
    if (jwtLevel.value) payload.level = jwtLevel.value
    
    jwtToken.value = await generateJWT(jwtSecretKey.value, payload)
    jwtError.value = ''
  } catch (err: any) {
    jwtError.value = `生成 Token 失敗: ${err.message || err}`
  }
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
</style>
