<template>
  <v-card-text style="height: 100%; padding: 4px; display: flex; flex-direction: column; overflow: hidden; min-height: 0; background-color: #ffffff;">
    <v-data-table
      :items="filteredLogs"
      :headers="headers"
      :items-per-page="-1"
      class="log-table"
      density="compact"
      style="flex: 1; min-height: 0; overflow: hidden;"
      fixed-header
      hide-default-footer
    >
      <template v-slot:item.timestamp="{ item }">
        <span class="log-time">{{ formatTime(item.timestamp) }}</span>
      </template>
      
      <template v-slot:item.type="{ item }">
        <v-chip :color="getColor(item.type)" size="small" variant="flat">
          <v-icon :icon="getIcon(item.type)" size="small" class="mr-1"></v-icon>
          {{ item.type }}
        </v-chip>
      </template>
      
      <template v-slot:item.message="{ item }">
        <div class="log-message">{{ item.message }}</div>
      </template>
      
      <template v-slot:item.data="{ item }">
        <v-btn
          v-if="item.data"
          icon="mdi-eye"
          size="small"
          variant="text"
          @click="showDataDialog(item)"
        ></v-btn>
      </template>
    </v-data-table>

    <!-- Data Dialog -->
    <v-dialog v-model="dataDialog.show" max-width="800">
      <v-card>
        <v-card-title>
          訊息資料
          <v-spacer></v-spacer>
          <v-btn icon="mdi-close" variant="text" @click="dataDialog.show = false"></v-btn>
        </v-card-title>
        <v-card-text>
          <pre class="data-preview">{{ JSON.stringify(dataDialog.data, null, 2) }}</pre>
        </v-card-text>
      </v-card>
    </v-dialog>
  </v-card-text>
</template>

<script setup lang="ts">
import { ref, computed } from 'vue'
import type { LogEntry } from '@/types'

const MAX_DISPLAY_LOGS = 200

const props = defineProps<{
  logs: LogEntry[]
  filterKeyword?: string
  selectedLevel: LogLevelFilter
}>()

type LogLevelFilter = 'all' | 'info' | 'warning' | 'error'

const levelRank: Record<Exclude<LogLevelFilter, 'all'>, number> = {
  info: 0,
  warning: 1,
  error: 2
}

const typeRank = (type: LogEntry['type']): number => {
  switch (type) {
    case 'error': return 2
    case 'warning': return 1
    default: return 0 // info / success / server
  }
}

const filteredLogs = computed(() => {
  let list = props.logs

  // Filter by level
  if (props.selectedLevel !== 'all') {
    const minRank = levelRank[props.selectedLevel]
    list = list.filter(log => typeRank(log.type) >= minRank)
  }
  
  // Filter by keyword
  if (props.filterKeyword) {
    const keyword = props.filterKeyword.toLowerCase()
    list = list.filter(log => {
      const messageMatch = log.message.toLowerCase().includes(keyword)
      const typeMatch = log.type.toLowerCase().includes(keyword)
      const dataMatch = log.data && JSON.stringify(log.data).toLowerCase().includes(keyword)
      return messageMatch || typeMatch || dataMatch
    })
  }

  // Keep only the latest N entries to avoid rendering huge tables
  const start = Math.max(0, list.length - MAX_DISPLAY_LOGS)
  return list.slice(start)
})

const dataDialog = ref({
  show: false,
  data: null as any
})

const headers = computed(() => [
  { title: '時間', key: 'timestamp', width: '120px', sortable: true },
  { title: '類型', key: 'type', width: '100px', sortable: true },
  { title: '訊息', key: 'message', sortable: false },
  { title: '資料', key: 'data', width: '80px', sortable: false }
])

const formatTime = (date: Date): string => {
  const timeStr = date.toLocaleTimeString('zh-TW', {
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit'
  })
  const milliseconds = date.getMilliseconds().toString().padStart(3, '0')
  return `${timeStr}.${milliseconds}`
}

const getIcon = (type: LogEntry['type']): string => {
  switch (type) {
    case 'info': return 'mdi-information'
    case 'error': return 'mdi-alert-circle'
    case 'warning': return 'mdi-alert'
    case 'success': return 'mdi-check-circle'
    case 'server': return 'mdi-server'
    default: return 'mdi-circle'
  }
}

const getColor = (type: LogEntry['type']): string => {
  switch (type) {
    case 'info': return 'info'
    case 'error': return 'error'
    case 'warning': return 'warning'
    case 'success': return 'success'
    case 'server': return 'primary'
    default: return 'grey'
  }
}

const showDataDialog = (item: LogEntry) => {
  dataDialog.value.data = item.data
  dataDialog.value.show = true
}
</script>

<style scoped>
.log-table {
  font-family: 'Monaco', 'Menlo', 'Courier New', monospace;
  font-size: 10px;
}

.log-table :deep(.v-data-table__td) {
  font-size: 10px;
  padding: 2px 6px;
  line-height: 1.2;
}

.log-table :deep(.v-data-table__th) {
  font-size: 10px;
  padding: 4px 6px;
  font-weight: 500;
}

.log-table :deep(.v-data-table__tbody tr) {
  height: auto;
  min-height: 24px;
}

.log-table :deep(.v-data-table) {
  height: 100% !important;
  display: flex;
  flex-direction: column;
  background-color: #ffffff !important;
}

.log-table :deep(.v-data-table__wrapper) {
  background-color: #ffffff !important;
}

.log-table :deep(.v-data-table__thead) {
  background-color: #f5f5f5 !important;
}

.log-table :deep(.v-data-table__tbody) {
  background-color: #ffffff !important;
}

.log-table :deep(.v-data-table__tbody tr) {
  background-color: #ffffff !important;
}

.log-table :deep(.v-data-table__tbody tr:hover) {
  background-color: #f5f5f5 !important;
}

.log-table :deep(.v-data-table__wrapper) {
  flex: 1;
  min-height: 0;
  overflow: auto !important;
  display: flex;
  flex-direction: column;
}

.log-table :deep(.v-data-table__thead) {
  position: sticky;
  top: 0;
  z-index: 1;
  background-color: #f5f5f5 !important;
}

.log-table :deep(.v-data-table__td) {
  color: #212121 !important;
  background-color: #ffffff !important;
}

.log-table :deep(.v-data-table__th) {
  color: #212121 !important;
  background-color: #f5f5f5 !important;
  font-weight: 600;
}

.log-time {
  color: #212121 !important;
  font-size: 9px;
  white-space: nowrap;
  font-weight: 500;
}

.log-message {
  color: #212121 !important;
  word-break: break-word;
  max-width: 400px;
  font-size: 10px;
  font-weight: 400;
}

.data-preview {
  background: rgba(0, 0, 0, 0.05);
  padding: 16px;
  border-radius: 4px;
  overflow-x: auto;
  font-size: 12px;
  max-height: 500px;
  overflow-y: auto;
}

</style>
