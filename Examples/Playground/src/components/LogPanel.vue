<template>
  <v-card-text>
    <div class="log-container">
      <div
        v-for="log in logs"
        :key="log.id"
        :class="['log-entry', `log-${log.type}`]"
      >
        <div class="log-header">
          <v-icon :icon="getIcon(log.type)" :color="getColor(log.type)" size="small" class="mr-2"></v-icon>
          <span class="log-time">{{ formatTime(log.timestamp) }}</span>
          <v-chip :color="getColor(log.type)" size="x-small" variant="flat" class="ml-2">
            {{ log.type }}
          </v-chip>
        </div>
        <div class="log-message">{{ log.message }}</div>
        <v-expansion-panels v-if="log.data" variant="accordion" density="compact" class="mt-2">
          <v-expansion-panel>
            <v-expansion-panel-title>查看資料</v-expansion-panel-title>
            <v-expansion-panel-text>
              <pre>{{ JSON.stringify(log.data, null, 2) }}</pre>
            </v-expansion-panel-text>
          </v-expansion-panel>
        </v-expansion-panels>
      </div>
    </div>
  </v-card-text>
</template>

<script setup lang="ts">
import { computed } from 'vue'
import type { LogEntry } from '@/types'

const props = defineProps<{
  logs: LogEntry[]
}>()

const formatTime = (date: Date): string => {
  return date.toLocaleTimeString('zh-TW', {
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    fractionalSecondDigits: 3
  })
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
</script>

<style scoped>
.log-container {
  max-height: 600px;
  overflow-y: auto;
  font-family: 'Monaco', 'Menlo', 'Courier New', monospace;
  font-size: 12px;
}

.log-entry {
  padding: 8px;
  margin-bottom: 8px;
  border-left: 3px solid;
  background: rgba(255, 255, 255, 0.05);
  border-radius: 4px;
}

.log-info {
  border-left-color: #2196F3;
}

.log-error {
  border-left-color: #F44336;
}

.log-warning {
  border-left-color: #FF9800;
}

.log-success {
  border-left-color: #4CAF50;
}

.log-server {
  border-left-color: #9C27B0;
}

.log-header {
  display: flex;
  align-items: center;
  margin-bottom: 4px;
}

.log-time {
  color: rgba(255, 255, 255, 0.6);
  font-size: 10px;
}

.log-message {
  color: rgba(255, 255, 255, 0.9);
}

pre {
  background: rgba(0, 0, 0, 0.3);
  padding: 8px;
  border-radius: 4px;
  overflow-x: auto;
  font-size: 11px;
}
</style>

