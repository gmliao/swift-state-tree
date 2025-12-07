<template>
  <v-card class="resizable-log-panel">
    <v-tabs v-model="localLogTab" color="blue-darken-2" density="compact">
      <v-tab value="messages">
        <v-icon icon="mdi-text-box" size="small" class="mr-1"></v-icon>
        Message Log
      </v-tab>
      <v-tab value="updates">
        <v-icon icon="mdi-update" size="small" class="mr-1"></v-icon>
        狀態更新歷史
      </v-tab>
    </v-tabs>
    
    <div class="resizable-container" :style="{ height: `${props.height}px`, maxHeight: `${props.height}px`, minHeight: `${props.height}px` }">
      <div class="resize-handle" @mousedown="startResize"></div>
      
      <v-window v-model="localLogTab" class="log-window">
        <v-window-item value="messages" style="height: 100%; display: flex; flex-direction: column;">
          <LogPanel :logs="logs" />
        </v-window-item>
        
        <v-window-item value="updates" style="height: 100%; display: flex; flex-direction: column;">
          <StateUpdatePanel :stateUpdates="stateUpdates" />
        </v-window-item>
      </v-window>
    </div>
  </v-card>
</template>

<script setup lang="ts">
import { ref, watch, withDefaults } from 'vue'
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
}>()

const localLogTab = ref(props.logTab)

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
</script>

<style scoped>
.resizable-log-panel {
  position: relative;
  background-color: #ffffff !important;
}

.resizable-log-panel :deep(.v-card) {
  background-color: #ffffff !important;
}

.resizable-container {
  position: relative;
  display: flex;
  flex-direction: column;
  overflow: hidden;
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

.log-window {
  flex: 1;
  min-height: 0;
  display: flex;
  flex-direction: column;
  height: 100%;
}

.log-window :deep(.v-window-item) {
  flex: 1;
  min-height: 0;
  display: flex;
  flex-direction: column;
  overflow: hidden;
  height: 100%;
}
</style>

