<template>
  <v-app>
    <v-app-bar color="primary" prominent>
      <v-app-bar-title>
        <v-icon icon="mdi-rocket-launch" class="mr-2"></v-icon>
        SwiftStateTree Playground
      </v-app-bar-title>
      <v-spacer></v-spacer>
      <v-chip :color="connectionStatus.color" variant="flat" class="mr-4">
        <v-icon :icon="connectionStatus.icon" class="mr-1"></v-icon>
        {{ connectionStatus.text }}
      </v-chip>
    </v-app-bar>

    <v-main>
      <v-container fluid>
        <v-row>
          <!-- Left Panel: Schema & Connection -->
          <v-col cols="12" md="4">
            <v-card class="mb-4">
              <v-card-title>
                <v-icon icon="mdi-file-upload" class="mr-2"></v-icon>
                Schema 設定
              </v-card-title>
              <v-card-text>
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
                  color="primary"
                  block
                  class="mt-4"
                  @click="parseSchema"
                  :disabled="!schemaJson"
                >
                  <v-icon icon="mdi-check" class="mr-2"></v-icon>
                  解析 Schema
                </v-btn>

                <v-alert
                  v-if="schemaError"
                  type="error"
                  density="compact"
                  class="mt-2"
                >
                  {{ schemaError }}
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

          <!-- Middle Panel: State Tree -->
          <v-col cols="12" md="4">
            <v-card>
              <v-card-title>
                <v-icon icon="mdi-file-tree" class="mr-2"></v-icon>
                狀態樹
              </v-card-title>
              <v-card-text>
                <StateTreeViewer
                  :state="currentState"
                  :schema="parsedSchema"
                  :stateUpdates="stateUpdates"
                />
              </v-card-text>
            </v-card>
          </v-col>

          <!-- Right Panel: Actions & Events -->
          <v-col cols="12" md="4">
            <v-tabs v-model="tab" color="primary">
              <v-tab value="actions">
                <v-icon icon="mdi-lightning-bolt" class="mr-2"></v-icon>
                Actions
              </v-tab>
              <v-tab value="events">
                <v-icon icon="mdi-broadcast" class="mr-2"></v-icon>
                Events
              </v-tab>
              <v-tab value="logs">
                <v-icon icon="mdi-text-box" class="mr-2"></v-icon>
                日誌
              </v-tab>
            </v-tabs>

            <v-window v-model="tab">
              <v-window-item value="actions">
                <ActionPanel
                  :schema="parsedSchema"
                  :connected="isConnected"
                  @send-action="handleSendAction"
                />
              </v-window-item>

              <v-window-item value="events">
                <EventPanel
                  :schema="parsedSchema"
                  :connected="isConnected"
                  @send-event="handleSendEvent"
                />
              </v-window-item>

              <v-window-item value="logs">
                <LogPanel :logs="logs" />
              </v-window-item>
            </v-window>
          </v-col>
        </v-row>

        <!-- Global message log at bottom -->
        <v-row class="mt-4">
          <v-col cols="12">
            <v-card>
              <v-card-title>
                <v-icon icon="mdi-text-box" class="mr-2"></v-icon>
                Message Log
              </v-card-title>
              <LogPanel :logs="logs" />
            </v-card>
          </v-col>
        </v-row>
      </v-container>
    </v-main>
  </v-app>
</template>

<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import StateTreeViewer from './components/StateTreeViewer.vue'
import ActionPanel from './components/ActionPanel.vue'
import EventPanel from './components/EventPanel.vue'
import LogPanel from './components/LogPanel.vue'
import { useWebSocket } from './composables/useWebSocket'
import { useSchema } from './composables/useSchema'

const tab = ref('actions')
const schemaFile = ref<File[] | null>(null)
const schemaJson = ref('')
const wsUrl = ref('ws://localhost:8080/game')

const { parsedSchema, error: schemaError, parseSchema, loadSchema } = useSchema(schemaJson)
const { 
  isConnected, 
  currentState, 
  logs, 
  stateUpdates,
  connect, 
  disconnect, 
  sendAction, 
  sendEvent 
} = useWebSocket(wsUrl, parsedSchema)

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

onMounted(() => {
  // Try to load default schema if available
  if (schemaJson.value) {
    parseSchema()
  }
})
</script>

<style>
.v-application {
  background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
  min-height: 100vh;
}
</style>
