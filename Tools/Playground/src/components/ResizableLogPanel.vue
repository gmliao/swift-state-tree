<template>
  <div class="resizable-log-panel" :style="{ height: `${props.height}px`, maxHeight: `${props.height}px`, minHeight: `${props.height}px` }">
    <div class="resize-handle" @mousedown="startResize"></div>
    
    <!-- Mobile/Tablet: Use tabs -->
    <div class="log-panel-mobile">
      <v-tabs v-model="localLogTab" color="blue-darken-2" density="compact" class="log-tabs">
        <v-tab value="messages">
          <v-icon icon="mdi-text-box" size="small" class="mr-1"></v-icon>
          Message Log
        </v-tab>
        <v-tab value="updates">
          <v-icon icon="mdi-update" size="small" class="mr-1"></v-icon>
          狀態更新歷史
        </v-tab>
      </v-tabs>
      
      <v-window v-model="localLogTab" class="log-window">
        <v-window-item value="messages" class="log-window-item">
          <div class="log-panel-mobile-container">
            <div class="log-panel-mobile-header">
              <div class="log-panel-header-left">
                <v-icon icon="mdi-text-box" size="small" class="mr-1"></v-icon>
                <span>Log</span>
                <v-btn
                  class="log-header-level-btn"
                  :color="currentLogLevelColor"
                  variant="text"
                  size="x-small"
                  density="comfortable"
                  @click="cycleLogLevel"
                >
                  [{{ currentLogLevelShortLabel }}]
                </v-btn>
              </div>
              <div class="log-panel-header-right">
                <v-text-field
                  v-model="logFilterKeyword"
                  label="過濾關鍵字"
                  prepend-inner-icon="mdi-filter"
                  variant="outlined"
                  density="compact"
                  clearable
                  hide-details
                  class="log-header-filter-input"
                ></v-text-field>
                <v-btn
                  icon="mdi-delete-sweep"
                  size="small"
                  variant="text"
                  @click="emit('clear-logs')"
                  title="清除 Message Log"
                ></v-btn>
              </div>
            </div>
            <div class="log-panel-mobile-content">
              <LogPanel :logs="logs" :filter-keyword="logFilterKeyword" :selected-level="selectedLevel" />
            </div>
          </div>
        </v-window-item>
        
        <v-window-item value="updates" class="log-window-item">
          <div class="log-panel-mobile-container">
            <div class="log-panel-mobile-header">
              <div class="log-panel-header-left">
                <v-icon icon="mdi-update" size="small" class="mr-1"></v-icon>
                <span>狀態更新歷史</span>
              </div>
              <div class="log-panel-header-right">
                <v-text-field
                  v-model="stateUpdatePathFilter"
                  label="過濾路徑"
                  prepend-inner-icon="mdi-folder-search"
                  variant="outlined"
                  density="compact"
                  clearable
                  hide-details
                  class="log-header-filter-input"
                ></v-text-field>
                <v-btn
                  icon="mdi-download"
                  size="small"
                  variant="text"
                  @click="exportStateUpdatesLog"
                  title="導出狀態更新日誌 (.log)"
                ></v-btn>
                <v-btn
                  icon="mdi-delete-sweep"
                  size="small"
                  variant="text"
                  @click="emit('clear-state-updates')"
                  title="清除狀態更新記錄"
                ></v-btn>
              </div>
            </div>
            <div class="log-panel-mobile-content">
              <StateUpdatePanel :stateUpdates="stateUpdates" :path-filter="stateUpdatePathFilter" />
            </div>
          </div>
        </v-window-item>
      </v-window>
    </div>
    
    <!-- Desktop: Side by side -->
    <div class="log-panel-desktop">
      <div class="log-panel-left">
        <div class="log-panel-header">
          <div class="log-panel-header-left">
            <v-icon icon="mdi-text-box" size="small" class="mr-1"></v-icon>
            <span>Log</span>
            <v-btn
              class="log-header-level-btn"
              :color="currentLogLevelColor"
              variant="text"
              size="x-small"
              density="comfortable"
              @click="cycleLogLevel"
            >
              [{{ currentLogLevelShortLabel }}]
            </v-btn>
          </div>
          <div class="log-panel-header-right">
            <v-text-field
              v-model="logFilterKeyword"
              label="過濾關鍵字"
              prepend-inner-icon="mdi-filter"
              variant="outlined"
              density="compact"
              clearable
              hide-details
              class="log-header-filter-input"
            ></v-text-field>
            <v-btn
              icon="mdi-delete-sweep"
              size="small"
              variant="text"
              @click="emit('clear-logs')"
              title="清除 Message Log"
            ></v-btn>
          </div>
        </div>
        <div class="log-panel-content">
          <LogPanel :logs="logs" :filter-keyword="logFilterKeyword" :selected-level="selectedLevel" />
        </div>
      </div>
      
      <div class="log-panel-divider"></div>
      
      <div class="log-panel-right">
        <div class="log-panel-header">
          <div class="log-panel-header-left">
            <v-icon icon="mdi-update" size="small" class="mr-1"></v-icon>
            <span>狀態更新歷史</span>
          </div>
          <div class="log-panel-header-right">
            <v-text-field
              v-model="stateUpdatePathFilter"
              label="過濾路徑"
              prepend-inner-icon="mdi-folder-search"
              variant="outlined"
              density="compact"
              clearable
              hide-details
              class="log-header-filter-input"
            ></v-text-field>
            <v-btn
              icon="mdi-download"
              size="small"
              variant="text"
              @click="exportStateUpdatesLog"
              title="導出狀態更新日誌 (.log)"
            ></v-btn>
            <v-btn
              icon="mdi-delete-sweep"
              size="small"
              variant="text"
              @click="emit('clear-state-updates')"
              title="清除狀態更新記錄"
            ></v-btn>
          </div>
        </div>
        <div class="log-panel-content">
          <StateUpdatePanel :stateUpdates="stateUpdates" :path-filter="stateUpdatePathFilter" />
        </div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, watch, computed } from 'vue'
import LogPanel from './LogPanel.vue'
import StateUpdatePanel from './StateUpdatePanel.vue'
import type { LogEntry } from '@/types'
import type { StateUpdateEntry } from '@/composables/useWebSocket'

const props = defineProps<{
  logTab: string
  logs: LogEntry[]
  stateUpdates: StateUpdateEntry[]
  height: number
}>()

const emit = defineEmits<{
  'update:logTab': [value: string]
  'update:height': [value: number]
  'clear-logs': []
  'clear-state-updates': []
}>()

const localLogTab = ref(props.logTab)
const logFilterKeyword = ref('')
const stateUpdatePathFilter = ref('')

type LogLevelFilter = 'all' | 'info' | 'warning' | 'error'

const selectedLevel = ref<LogLevelFilter>('info')

const levelOrder: LogLevelFilter[] = ['all', 'info', 'warning', 'error']

const logLevelShortLabelMap: Record<LogLevelFilter, string> = {
  all: 'All',
  info: 'Info',
  warning: 'Warn',
  error: 'Error'
}

const logLevelColorMap: Record<LogLevelFilter, string> = {
  all: 'grey',
  info: 'info',
  warning: 'warning',
  error: 'error'
}

const currentLogLevelShortLabel = computed(() => logLevelShortLabelMap[selectedLevel.value])
const currentLogLevelColor = computed(() => logLevelColorMap[selectedLevel.value])

const cycleLogLevel = () => {
  const currentIndex = levelOrder.indexOf(selectedLevel.value)
  const nextIndex = (currentIndex + 1) % levelOrder.length
  selectedLevel.value = levelOrder[nextIndex]
}

watch(() => props.logTab, (newVal) => {
  localLogTab.value = newVal
})

watch(localLogTab, (newVal) => {
  emit('update:logTab', newVal)
})

const startResize = (e: MouseEvent) => {
  e.preventDefault()
  const startY = e.clientY
  const startHeight = props.height
  
  const doResize = (moveEvent: MouseEvent) => {
    const deltaY = moveEvent.clientY - startY
    const newHeight = Math.max(150, Math.min(600, startHeight - deltaY))
    emit('update:height', newHeight)
  }
  
  const stopResize = () => {
    document.removeEventListener('mousemove', doResize)
    document.removeEventListener('mouseup', stopResize)
    document.body.style.cursor = ''
    document.body.style.userSelect = ''
  }
  
  document.addEventListener('mousemove', doResize)
  document.addEventListener('mouseup', stopResize)
  document.body.style.cursor = 'row-resize'
  document.body.style.userSelect = 'none'
}

const exportStateUpdatesLog = () => {
  if (!props.stateUpdates || props.stateUpdates.length === 0) {
    return
  }
  
  // Format log entries
  const logLines: string[] = []
  logLines.push(`# State Updates Log`)
  logLines.push(`# Generated: ${new Date().toISOString()}`)
  logLines.push(`# Total Updates: ${props.stateUpdates.length}`)
  logLines.push('')
  
  for (const update of props.stateUpdates) {
    const timestamp = update.timestamp.toISOString()
    logLines.push(`[${timestamp}] ${update.type} - ${update.message || 'State Update'}`)
    
    if (update.patches && update.patches.length > 0) {
      for (const patch of update.patches) {
        logLines.push(`  ${patch.op} ${patch.path}`)
        if (patch.value !== undefined) {
          const valueStr = typeof patch.value === 'object' 
            ? JSON.stringify(patch.value, null, 2).split('\n').map(line => `    ${line}`).join('\n')
            : String(patch.value)
          logLines.push(`    Value: ${valueStr}`)
        }
      }
    }
    
    if (update.affectedPaths && update.affectedPaths.length > 0) {
      logLines.push(`  Affected Paths: ${update.affectedPaths.join(', ')}`)
    }
    
    logLines.push('')
  }
  
  // Create blob and download
  const logContent = logLines.join('\n')
  const blob = new Blob([logContent], { type: 'text/plain;charset=utf-8' })
  const url = URL.createObjectURL(blob)
  const link = document.createElement('a')
  link.href = url
  link.download = `state-updates-${new Date().toISOString().replace(/[:.]/g, '-')}.log`
  document.body.appendChild(link)
  link.click()
  document.body.removeChild(link)
  URL.revokeObjectURL(url)
}
</script>

<style scoped>
.resizable-log-panel {
  position: relative;
  background-color: #ffffff;
  width: 100%;
  display: flex;
  flex-direction: column;
  overflow: hidden;
  border: 1px solid rgba(var(--v-border-color), var(--v-border-opacity));
  border-radius: 4px;
}

.resize-handle {
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  height: 4px;
  background: rgba(0, 0, 0, 0.1);
  cursor: row-resize;
  z-index: 10;
  transition: background 0.2s;
}

.resize-handle:hover {
  background: rgba(0, 0, 0, 0.2);
}

/* Mobile/Tablet: Show tabs, hide side-by-side */
.log-panel-mobile {
  display: flex;
  flex-direction: column;
  height: 100%;
  overflow: hidden;
}

.log-panel-desktop {
  display: none;
}

.log-tabs {
  flex-shrink: 0;
  border-bottom: 1px solid rgba(var(--v-border-color), var(--v-border-opacity));
}

.log-tabs :deep(.v-tab) {
  font-size: 12px;
  min-height: 32px;
}

.log-window {
  flex: 1;
  min-height: 0;
  display: flex;
  flex-direction: column;
  height: 100%;
}

.log-window-item {
  flex: 1;
  min-height: 0;
  display: flex;
  flex-direction: column;
  overflow: hidden;
  height: 100%;
}

.log-panel-mobile-container {
  display: flex;
  flex-direction: column;
  height: 100%;
  overflow: hidden;
}

.log-panel-mobile-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 8px 16px;
  font-size: 0.875rem;
  font-weight: 500;
  border-bottom: 1px solid rgba(var(--v-border-color), var(--v-border-opacity));
  flex-shrink: 0;
  background-color: rgba(var(--v-theme-surface), 0.5);
}

.log-panel-mobile-content {
  flex: 1;
  min-height: 0;
  overflow: hidden;
  display: flex;
  flex-direction: column;
}

.log-header-level-btn {
  margin-left: 4px;
  text-transform: none;
  font-size: 0.75rem;
  padding: 0 6px;
  min-width: auto;
}

/* Desktop: Show side-by-side, hide tabs */
@media (min-width: 960px) {
  .log-panel-mobile {
    display: none;
  }
  
  .log-panel-desktop {
    display: flex;
    flex-direction: row;
    height: 100%;
    overflow: hidden;
  }
  
  .log-panel-left,
  .log-panel-right {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }
  
  .log-panel-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 8px 16px;
    height: 45px;
    font-size: 0.875rem;
    font-weight: 500;
    border-bottom: 1px solid rgba(var(--v-border-color), var(--v-border-opacity));
    flex-shrink: 0;
    background-color: rgba(var(--v-theme-surface), 0.5);
  }
  
  .log-panel-header-left {
    display: flex;
    align-items: center;
  }
  
  .log-panel-header-right {
    display: flex;
    align-items: center;
    gap: 8px;
    flex: 1;
    justify-content: flex-end;
  }
  
  .log-header-filter-input {
    min-width: 250px;
    max-width: 400px;
    flex: 1;
    font-size: 0.75rem;
  }
  
  .log-header-filter-input :deep(.v-field) {
    font-size: 0.75rem;
    min-height: 32px;
  }
  
  .log-header-filter-input :deep(.v-field__input) {
    font-size: 0.75rem;
    min-height: 32px;
    padding: 0 8px;
  }
  
  .log-panel-content {
    flex: 1;
    min-height: 0;
    overflow: hidden;
    display: flex;
    flex-direction: column;
  }
  
  .log-panel-divider {
    width: 1px;
    background-color: rgba(var(--v-border-color), var(--v-border-opacity));
    flex-shrink: 0;
  }
}

/* Ensure child components fill the container */
.log-panel-content :deep(.v-card-text),
.log-window-item :deep(.v-card-text) {
  flex: 1;
  min-height: 0;
  overflow: hidden;
  height: 100%;
  display: flex;
  flex-direction: column;
  padding: 4px !important;
}

.log-panel-content :deep(.v-data-table),
.log-window-item :deep(.v-data-table) {
  flex: 1;
  min-height: 0;
  overflow: hidden;
  height: 100%;
}
</style>
