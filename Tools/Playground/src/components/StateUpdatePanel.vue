<template>
  <v-card-text style="height: 100%; padding: 4px; display: flex; flex-direction: column; overflow: hidden; background-color: #ffffff;">
    <!-- Recording Mode -->
    <div v-if="viewMode === 'recording'" style="flex: 1; overflow: hidden; min-height: 0; display: flex; flex-direction: column;">
      <!-- Recording Controls -->
      <div style="padding: 8px; border-bottom: 1px solid rgba(0,0,0,0.12); display: flex; align-items: center; gap: 8px; flex-shrink: 0;">
        <v-btn
          :color="isRecording ? 'error' : 'success'"
          :icon="isRecording ? 'mdi-stop' : 'mdi-record'"
          size="small"
          @click="toggleRecording"
        >
          {{ isRecording ? '結束' : '錄製' }}
        </v-btn>
        <v-chip
          v-if="isRecording"
          color="error"
          size="small"
          variant="flat"
        >
          <v-icon icon="mdi-record" size="small" class="mr-1"></v-icon>
          錄製中... {{ formatDuration(recordingDuration) }}
        </v-chip>
        <v-spacer></v-spacer>
        <span v-if="isRecording" style="font-size: 11px; color: #666;">
          已記錄 {{ currentRecording.length }} 個更新
        </span>
      </div>

      <!-- Recording List -->
      <div style="flex: 1; overflow: auto; padding: 8px;">
        <v-alert
          v-if="recordings.length === 0"
          type="info"
          density="compact"
          variant="text"
          class="ma-2"
          style="font-size: 10px; padding: 4px 8px;"
        >
          尚無錄製記錄，點擊「錄製」開始錄製
        </v-alert>
        <v-list v-else density="compact">
          <v-list-item
            v-for="recording in recordings"
            :key="recording.id"
            style="border-bottom: 1px solid rgba(0,0,0,0.12);"
          >
            <template v-slot:prepend>
              <v-icon icon="mdi-record-rec" color="error" size="small"></v-icon>
            </template>
            <v-list-item-title style="font-size: 11px; font-weight: 500;">
              {{ formatDateTime(recording.startTime) }}
            </v-list-item-title>
            <v-list-item-subtitle style="font-size: 10px; color: #666;">
              長度: {{ formatDuration(recording.duration) }} | 
              更新數: {{ recording.updates.length }} | 
              大小: {{ formatBytes(recording.totalSize) }}
            </v-list-item-subtitle>
            <template v-slot:append>
              <div style="display: flex; gap: 4px;">
                <v-btn
                  icon="mdi-eye"
                  size="x-small"
                  variant="text"
                  density="compact"
                  @click="viewRecording(recording)"
                  title="檢視"
                ></v-btn>
                <v-btn
                  icon="mdi-delete"
                  size="x-small"
                  variant="text"
                  density="compact"
                  color="error"
                  @click="deleteRecording(recording.id)"
                  title="刪除"
                ></v-btn>
                <v-btn
                  icon="mdi-download"
                  size="x-small"
                  variant="text"
                  density="compact"
                  color="primary"
                  @click="exportRecording(recording)"
                  title="匯出JSON"
                ></v-btn>
              </div>
            </template>
          </v-list-item>
        </v-list>
      </div>
    </div>

    <!-- Realtime Mode (Table View) -->
    <div v-else-if="viewMode === 'realtime'" style="flex: 1; overflow: hidden; min-height: 0; display: flex; flex-direction: column;">
      <v-alert
        v-if="sortedTableData.length === 0"
        type="info"
        density="compact"
        variant="text"
        class="ma-2"
        style="font-size: 10px; padding: 4px 8px; flex-shrink: 0;"
      >
        {{ pathFilter ? '沒有符合過濾條件的更新記錄' : '尚無狀態更新記錄' }}
      </v-alert>
      
      <v-data-table
        v-else
        :items="sortedTableData"
        :headers="headers"
        :items-per-page="-1"
        class="state-update-table"
        density="compact"
        style="flex: 1; min-height: 0; overflow: hidden;"
        fixed-header
        hide-default-footer
      >
        <template v-slot:item.timestamp="{ item }">
          <span class="update-time">{{ formatTime(item.timestamp) }}</span>
        </template>
        
        <template v-slot:item.path="{ item }">
          <code class="update-path">{{ item.path }}</code>
        </template>
        
        <template v-slot:item.op="{ item }">
          <v-chip :color="getOpColor(item.op)" size="x-small" variant="flat" style="font-size: 9px; height: 18px;">
            {{ item.op }}
          </v-chip>
        </template>
        
        <template v-slot:item.value="{ item }">
          <div class="update-value">
            <div v-if="getValueSegments(item.value).length" class="value-segments">
              <div
                v-for="segment in getValueSegments(item.value)"
                :key="segment.key"
                class="value-segment"
              >
                <span class="segment-label">{{ segment.key }}</span>
                <span class="segment-value">{{ segment.value }}</span>
              </div>
            </div>
            <pre v-else-if="item.value && typeof item.value === 'object'">{{ JSON.stringify(item.value, null, 2) }}</pre>
            <span v-else>{{ item.value ?? '-' }}</span>
          </div>
        </template>
        
        <template v-slot:item.debug="{ item }">
          <div class="update-debug">
            <span v-if="item.tickId !== null && item.tickId !== undefined" class="debug-item">
              Tick: {{ item.tickId }}
            </span>
            <span v-if="item.messageSize" class="debug-item">
              Size: {{ formatBytes(item.messageSize) }}
            </span>
            <span v-if="item.sequenceNumber !== undefined" class="debug-item">
              #{{ item.sequenceNumber }}
            </span>
          </div>
        </template>
        
        <template v-slot:footer.prepend>
          <div class="footer-filters">
            <v-text-field
              v-model="pathFilter"
              label="過濾路徑"
              prepend-inner-icon="mdi-folder-search"
              variant="outlined"
              density="compact"
              clearable
              hide-details
              class="footer-filter-input"
            ></v-text-field>
          </div>
        </template>
      </v-data-table>
    </div>

    <!-- Recording View Dialog -->
    <v-dialog v-model="showRecordingView" max-width="90%" max-height="90%">
      <v-card>
        <v-card-title>
          <span>錄製內容</span>
          <v-spacer></v-spacer>
          <v-btn icon="mdi-close" size="small" variant="text" @click="showRecordingView = false"></v-btn>
        </v-card-title>
        <v-card-text style="max-height: 70vh; overflow: auto;">
          <div v-if="viewingRecording">
            <div style="margin-bottom: 16px; padding: 8px; background-color: #f5f5f5; border-radius: 4px;">
              <div style="font-size: 12px; font-weight: 500; margin-bottom: 4px;">
                開始時間: {{ formatDateTime(viewingRecording.startTime) }}
              </div>
              <div style="font-size: 11px; color: #666;">
                長度: {{ formatDuration(viewingRecording.duration) }} | 
                更新數: {{ viewingRecording.updates.length }} | 
                大小: {{ formatBytes(viewingRecording.totalSize) }}
              </div>
            </div>
            <div
              v-for="(update, index) in viewingRecording.updates"
              :key="update.id"
              class="update-entry"
            >
              <div class="update-header">
                <span class="update-index">#{{ update.sequenceNumber ?? index }}</span>
                <span class="update-type">{{ update.type }}</span>
                <span class="update-timestamp">{{ formatTime(update.timestamp) }}</span>
                <span v-if="update.tickId !== null && update.tickId !== undefined" class="update-tickid">
                  Tick: {{ update.tickId }}
                </span>
                <span v-if="update.messageSize" class="update-size">
                  Size: {{ formatBytes(update.messageSize) }}
                </span>
              </div>
              <pre class="update-json">{{ formatUpdateJson(update) }}</pre>
            </div>
          </div>
        </v-card-text>
        <v-card-actions>
          <v-spacer></v-spacer>
          <v-btn @click="showRecordingView = false">關閉</v-btn>
        </v-card-actions>
      </v-card>
    </v-dialog>
  </v-card-text>
</template>

<script setup lang="ts">
import { ref, computed, watch, onUnmounted } from 'vue'
import type { StateUpdateEntry } from '@/composables/useWebSocket'

interface Recording {
  id: string
  startTime: Date
  endTime: Date
  duration: number // milliseconds
  updates: StateUpdateEntry[]
  totalSize: number
}

const props = defineProps<{
  stateUpdates: StateUpdateEntry[]
  pathFilter?: string
  viewMode?: 'recording' | 'realtime'
}>()

const pathFilter = ref(props.pathFilter || '')
const viewMode = ref<'recording' | 'realtime'>(props.viewMode || 'recording')

// Recording state
const isRecording = ref(false)
const recordingStartTime = ref<Date | null>(null)
const currentRecording = ref<StateUpdateEntry[]>([])
const recordings = ref<Recording[]>([])
const recordingDuration = ref(0)
const recordingTimer = ref<number | null>(null)

// Recording view dialog
const showRecordingView = ref(false)
const viewingRecording = ref<Recording | null>(null)

// Watch external filter prop changes
watch(() => props.pathFilter, (newVal) => {
  pathFilter.value = newVal || ''
})

watch(() => props.viewMode, (newVal) => {
  if (newVal) {
    viewMode.value = newVal
  }
})

// Watch for new state updates when recording
watch(() => props.stateUpdates, (newUpdates) => {
  if (isRecording.value && newUpdates.length > 0) {
    // Get only new updates (those not in currentRecording)
    const existingIds = new Set(currentRecording.value.map(u => u.id))
    const newEntries = newUpdates.filter(u => !existingIds.has(u.id))
    currentRecording.value.push(...newEntries)
  }
}, { deep: true })

// Recording controls
const toggleRecording = () => {
  if (isRecording.value) {
    stopRecording()
  } else {
    startRecording()
  }
}

const startRecording = () => {
  isRecording.value = true
  recordingStartTime.value = new Date()
  currentRecording.value = []
  recordingDuration.value = 0
  
  // Start duration timer
  recordingTimer.value = window.setInterval(() => {
    if (recordingStartTime.value) {
      recordingDuration.value = Date.now() - recordingStartTime.value.getTime()
    }
  }, 100)
}

const stopRecording = () => {
  if (!isRecording.value || !recordingStartTime.value) return
  
  isRecording.value = false
  const endTime = new Date()
  const duration = endTime.getTime() - recordingStartTime.value.getTime()
  
  if (recordingTimer.value !== null) {
    clearInterval(recordingTimer.value)
    recordingTimer.value = null
  }
  
  // Calculate total size
  const totalSize = currentRecording.value.reduce((sum, update) => {
    return sum + (update.messageSize || 0)
  }, 0)
  
  // Save recording
  const recording: Recording = {
    id: Date.now().toString() + Math.random().toString(36).substr(2, 9),
    startTime: recordingStartTime.value,
    endTime: endTime,
    duration: duration,
    updates: [...currentRecording.value],
    totalSize: totalSize
  }
  
  recordings.value.unshift(recording) // Add to beginning
  
  // Reset
  currentRecording.value = []
  recordingStartTime.value = null
  recordingDuration.value = 0
}

const deleteRecording = (id: string) => {
  const index = recordings.value.findIndex(r => r.id === id)
  if (index !== -1) {
    recordings.value.splice(index, 1)
  }
}

const viewRecording = (recording: Recording) => {
  viewingRecording.value = recording
  showRecordingView.value = true
}

const exportRecording = (recording: Recording) => {
  const jsonStr = JSON.stringify({
    id: recording.id,
    startTime: recording.startTime.toISOString(),
    endTime: recording.endTime.toISOString(),
    duration: recording.duration,
    totalSize: recording.totalSize,
    updateCount: recording.updates.length,
    updates: recording.updates.map(u => ({
      id: u.id,
      timestamp: u.timestamp.toISOString(),
      type: u.type,
      message: u.message,
      patchCount: u.patchCount,
      sequenceNumber: u.sequenceNumber,
      ...(u.tickId !== null && u.tickId !== undefined && { tickId: u.tickId }),
      ...(u.messageSize && { messageSize: u.messageSize }),
      ...(u.direction && { direction: u.direction }),
      ...(u.landID && { landID: u.landID }),
      ...(u.playerID && { playerID: u.playerID }),
      ...(u.affectedPaths && u.affectedPaths.length > 0 && { affectedPaths: u.affectedPaths }),
      ...(u.patches && u.patches.length > 0 && { patches: u.patches })
    }))
  }, null, 2)
  
  const blob = new Blob([jsonStr], { type: 'application/json' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = `recording-${recording.id}.json`
  document.body.appendChild(a)
  a.click()
  document.body.removeChild(a)
  URL.revokeObjectURL(url)
}

// Format functions
const formatTime = (date: Date): string => {
  return date.toLocaleTimeString('zh-TW', {
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    ...({ fractionalSecondDigits: 3 } as any)
  })
}

const formatDateTime = (date: Date): string => {
  return date.toLocaleString('zh-TW', {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    ...({ fractionalSecondDigits: 3 } as any)
  })
}

const formatDuration = (ms: number): string => {
  const seconds = Math.floor(ms / 1000)
  const minutes = Math.floor(seconds / 60)
  const hours = Math.floor(minutes / 60)
  
  if (hours > 0) {
    return `${hours}:${String(minutes % 60).padStart(2, '0')}:${String(seconds % 60).padStart(2, '0')}`
  } else if (minutes > 0) {
    return `${minutes}:${String(seconds % 60).padStart(2, '0')}`
  } else {
    return `${seconds}.${String(Math.floor((ms % 1000) / 100)).padStart(1, '0')}s`
  }
}

const formatBytes = (bytes: number): string => {
  if (bytes === 0) return '0 B'
  const k = 1024
  const sizes = ['B', 'KB', 'MB']
  const i = Math.floor(Math.log(bytes) / Math.log(k))
  return Math.round((bytes / Math.pow(k, i)) * 100) / 100 + ' ' + sizes[i]
}

const formatUpdateJson = (update: StateUpdateEntry): string => {
  const jsonObj: any = {
    id: update.id,
    timestamp: update.timestamp.toISOString(),
    type: update.type,
    message: update.message,
    patchCount: update.patchCount,
    sequenceNumber: update.sequenceNumber,
    ...(update.tickId !== null && update.tickId !== undefined && { tickId: update.tickId }),
    ...(update.messageSize && { messageSize: update.messageSize }),
    ...(update.direction && { direction: update.direction }),
    ...(update.landID && { landID: update.landID }),
    ...(update.playerID && { playerID: update.playerID }),
    ...(update.affectedPaths && update.affectedPaths.length > 0 && { affectedPaths: update.affectedPaths }),
    ...(update.patches && update.patches.length > 0 && { patches: update.patches })
  }
  
  return JSON.stringify(jsonObj, null, 2)
}

// Realtime mode table data
interface TableRow {
  id: string
  timestamp: Date
  path: string
  op: string
  value: any
  tickId?: number | null
  messageSize?: number
  sequenceNumber?: number
}

const headers = computed(() => [
  { title: '時間', key: 'timestamp', width: '100px', sortable: true },
  { title: '路徑', key: 'path', sortable: true },
  { title: '操作', key: 'op', width: '80px', sortable: true },
  { title: '數值', key: 'value', sortable: false },
  { title: 'Debug', key: 'debug', width: '150px', sortable: false }
])

const tableData = computed<TableRow[]>(() => {
  if (!props.stateUpdates || props.stateUpdates.length === 0) {
    return []
  }
  
  const rows: TableRow[] = []
  
  for (const update of props.stateUpdates) {
    if (!update.patches || update.patches.length === 0) {
      rows.push({
        id: update.id,
        timestamp: update.timestamp,
        path: '/',
        op: update.type,
        value: update.message || '-',
        tickId: update.tickId,
        messageSize: update.messageSize,
        sequenceNumber: update.sequenceNumber
      })
      continue
    }
    
    for (const patch of update.patches) {
      rows.push({
        id: `${update.id}-${patch.path}`,
        timestamp: update.timestamp,
        path: patch.path || '/',
        op: patch.op || update.type,
        value: patch.value !== undefined ? patch.value : null,
        tickId: update.tickId,
        messageSize: update.messageSize,
        sequenceNumber: update.sequenceNumber
      })
    }
  }
  
  return rows
})

const sortedTableData = computed(() => {
  let filtered = [...tableData.value]
  
  if (pathFilter.value) {
    const filter = pathFilter.value.toLowerCase().trim()
    const normalizedFilter = filter.startsWith('/') ? filter : `/${filter}`
    filtered = filtered.filter(row => {
      const path = row.path.toLowerCase()
      return path.includes(normalizedFilter) || 
             path.includes(filter) ||
             path.split('/').some(segment => segment.includes(filter.replace('/', '')))
    })
  }
  
  const sorted = filtered.sort((a, b) => 
    b.timestamp.getTime() - a.timestamp.getTime()
  )

  const pathCount: Record<string, number> = {}
  const limited: TableRow[] = []
  for (const row of sorted) {
    const pathKey = row.path || '/'
    const count = pathCount[pathKey] ?? 0
    if (count < 3) {
      limited.push(row)
      pathCount[pathKey] = count + 1
    }
  }
  
  return limited
})

const getOpColor = (op: string): string => {
  switch (op) {
    case 'add': return 'success'
    case 'replace': return 'info'
    case 'remove': return 'error'
    case 'firstSync': return 'primary'
    case 'snapshot': return 'primary'
    case 'diff': return 'warning'
    default: return 'grey'
  }
}

const normalizeValue = (value: any): any => {
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    const keys = Object.keys(value)
    if (keys.length === 1) {
      const onlyKey = keys[0]
      const inner = value[onlyKey]
      if (inner && typeof inner === 'object' && !Array.isArray(inner)) {
        const innerKeys = Object.keys(inner)
        if (innerKeys.length === 1 && innerKeys[0] === '') {
          return { [onlyKey]: inner[''] }
        }
      }
    }
  }
  return value
}

const getValueSegments = (value: any): Array<{ key: string; value: string }> => {
  const normalized = normalizeValue(value)

  if (normalized && typeof normalized === 'object' && !Array.isArray(normalized)) {
    const keys = Object.keys(normalized)
    if (keys.length > 0 && keys.length <= 6) {
      return keys.map(key => {
        const v = normalized[key]
        const rendered = typeof v === 'object'
          ? JSON.stringify(v)
          : String(v)
        return { key, value: rendered }
      })
    }
  }

  if (normalized === null || typeof normalized !== 'object') {
    return [{ key: 'value', value: String(normalized) }]
  }

  return []
}

// Cleanup on unmount
onUnmounted(() => {
  if (recordingTimer.value !== null) {
    clearInterval(recordingTimer.value)
  }
})
</script>

<style scoped>
.state-update-table {
  font-family: 'Monaco', 'Menlo', 'Courier New', monospace;
  font-size: 10px;
}

.state-update-table :deep(.v-data-table__td) {
  font-size: 10px;
  padding: 2px 6px;
  line-height: 1.2;
}

.state-update-table :deep(.v-data-table__th) {
  font-size: 10px;
  padding: 4px 6px;
  font-weight: 500;
}

.state-update-table :deep(.v-data-table__tbody tr) {
  height: auto;
  min-height: 24px;
}

.state-update-table :deep(.v-data-table) {
  height: 100% !important;
  display: flex;
  flex-direction: column;
  background-color: #ffffff !important;
}

.state-update-table :deep(.v-data-table__wrapper) {
  background-color: #ffffff !important;
}

.state-update-table :deep(.v-data-table__thead) {
  background-color: #f5f5f5 !important;
}

.state-update-table :deep(.v-data-table__tbody) {
  background-color: #ffffff !important;
}

.state-update-table :deep(.v-data-table__tbody tr) {
  background-color: #ffffff !important;
}

.state-update-table :deep(.v-data-table__tbody tr:hover) {
  background-color: #f5f5f5 !important;
}

.state-update-table :deep(.v-data-table-footer) {
  background-color: #ffffff !important;
}

.state-update-table :deep(.v-data-table__wrapper) {
  flex: 1;
  min-height: 0;
  overflow: auto !important;
  display: flex;
  flex-direction: column;
}

.state-update-table :deep(.v-data-table__thead) {
  position: sticky;
  top: 0;
  z-index: 1;
  background-color: #f5f5f5 !important;
}

.state-update-table :deep(.v-data-table__td) {
  color: #212121 !important;
  background-color: #ffffff !important;
}

.state-update-table :deep(.v-data-table__th) {
  color: #212121 !important;
  background-color: #f5f5f5 !important;
  font-weight: 600;
}

.update-time {
  color: #212121 !important;
  font-size: 9px;
  white-space: nowrap;
  font-weight: 500;
}

.update-path {
  color: #212121 !important;
  font-size: 9px;
  word-break: break-all;
  font-weight: 500;
}

.update-value {
  color: #212121 !important;
  font-size: 9px;
  max-width: 300px;
  overflow-x: auto;
  font-weight: 400;
}

.update-debug {
  display: flex;
  flex-direction: column;
  gap: 2px;
  font-size: 8px;
}

.debug-item {
  color: #666;
  font-weight: 500;
}

.value-segments {
  display: flex;
  flex-direction: column;
  gap: 2px;
}

.value-segment {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  background: #f1f5f9;
  border-radius: 4px;
  padding: 2px 4px;
  font-size: 9px;
  width: fit-content;
}

.segment-label {
  color: #475569;
  font-weight: 600;
}

.segment-value {
  color: #0f172a;
  font-weight: 500;
  word-break: break-all;
}

.update-value pre {
  margin: 0;
  font-size: 8px;
  max-height: 80px;
  overflow-y: auto;
  line-height: 1.2;
  color: #212121 !important;
  font-weight: 400;
}

.footer-filters {
  display: flex;
  gap: 6px;
  align-items: center;
  margin-right: auto;
}

.footer-filter-input {
  max-width: 180px;
  font-size: 9px;
}

.footer-filter-input :deep(.v-field) {
  font-size: 9px;
  min-height: 24px;
}

.footer-filter-input :deep(.v-field__input) {
  font-size: 9px;
  min-height: 24px;
  padding: 0 6px;
}

.footer-filter-input :deep(.v-label) {
  font-size: 9px;
  transform: translateY(-50%) scale(0.85);
}

.footer-filter-input :deep(.v-field__prepend-inner) {
  padding-top: 0;
  padding-bottom: 0;
}

.footer-filter-input :deep(.v-icon) {
  font-size: 14px;
}

.state-update-table :deep(.v-data-table-footer) {
  padding: 2px 8px;
  min-height: 36px;
  display: flex;
  align-items: center;
  justify-content: space-between;
}

/* Recording view styles */
.update-entry {
  margin-bottom: 16px;
  border: 1px solid rgba(0, 0, 0, 0.12);
  border-radius: 4px;
  background-color: #fafafa;
  overflow: hidden;
}

.update-header {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 6px 12px;
  background-color: #f5f5f5;
  border-bottom: 1px solid rgba(0, 0, 0, 0.12);
  font-size: 11px;
  font-weight: 500;
  flex-wrap: wrap;
}

.update-index {
  color: #666;
  font-weight: 600;
}

.update-type {
  color: #1976d2;
  font-weight: 600;
  text-transform: uppercase;
}

.update-timestamp {
  color: #666;
  margin-left: auto;
}

.update-tickid {
  color: #388e3c;
  font-weight: 500;
}

.update-size {
  color: #7b1fa2;
  font-weight: 500;
}

.update-json {
  margin: 0;
  padding: 12px;
  font-family: 'Monaco', 'Menlo', 'Courier New', monospace;
  font-size: 11px;
  line-height: 1.4;
  background-color: #ffffff;
  color: #212121;
  overflow-x: auto;
  white-space: pre;
  word-wrap: normal;
  max-height: 400px;
  overflow-y: auto;
}
</style>
