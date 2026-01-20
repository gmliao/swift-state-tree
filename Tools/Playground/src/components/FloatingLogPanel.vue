<template>
  <div 
    class="floating-log-panel"
    :style="floatingStyle"
    v-show="isVisible"
  >
    <!-- Title Bar (draggable) -->
    <div 
      class="floating-title-bar"
      @mousedown="startDrag"
      @touchstart="startDrag"
    >
      <div class="title-content">
        <v-icon icon="mdi-dock-window" size="small" class="mr-2"></v-icon>
        <span class="title-text">日誌面板</span>
      </div>
      <div class="title-actions">
        <v-btn
          icon="mdi-dock-bottom"
          size="x-small"
          variant="text"
          density="comfortable"
          @click="$emit('dock')"
          title="固定到底部"
        ></v-btn>
        <v-btn
          icon="mdi-close"
          size="x-small"
          variant="text"
          density="comfortable"
          @click="$emit('close')"
          title="關閉"
        ></v-btn>
      </div>
    </div>

    <!-- Content Area -->
    <div class="floating-content">
      <ResizableLogPanel
        :height="contentHeight"
        :logTab="logTab"
        :logs="logs"
        :stateUpdates="stateUpdates"
        @update:logTab="$emit('update:logTab', $event)"
        @update:height="handleHeightUpdate"
        @clear-logs="$emit('clear-logs')"
        @clear-state-updates="$emit('clear-state-updates')"
        :is-floating="true"
      />
    </div>

    <!-- Resize Handles -->
    <div class="resize-handle resize-e" @mousedown="startResize($event, 'e')" @touchstart="startResize($event, 'e')"></div>
    <div class="resize-handle resize-s" @mousedown="startResize($event, 's')" @touchstart="startResize($event, 's')"></div>
    <div class="resize-handle resize-w" @mousedown="startResize($event, 'w')" @touchstart="startResize($event, 'w')"></div>
    <div class="resize-handle resize-n" @mousedown="startResize($event, 'n')" @touchstart="startResize($event, 'n')"></div>
    <div class="resize-handle resize-se" @mousedown="startResize($event, 'se')" @touchstart="startResize($event, 'se')"></div>
    <div class="resize-handle resize-sw" @mousedown="startResize($event, 'sw')" @touchstart="startResize($event, 'sw')"></div>
    <div class="resize-handle resize-ne" @mousedown="startResize($event, 'ne')" @touchstart="startResize($event, 'ne')"></div>
    <div class="resize-handle resize-nw" @mousedown="startResize($event, 'nw')" @touchstart="startResize($event, 'nw')"></div>
  </div>
</template>

<script setup lang="ts">
import { ref, computed } from 'vue'
import ResizableLogPanel from './ResizableLogPanel.vue'
import type { LogEntry } from '@/types'
import type { StateUpdateEntry } from '@/composables/useWebSocket'

const props = defineProps<{
  logTab: string
  logs: LogEntry[]
  stateUpdates: StateUpdateEntry[]
  height: number
  isVisible: boolean
}>()

const emit = defineEmits<{
  'update:logTab': [value: string]
  'update:height': [value: number]
  'clear-logs': []
  'clear-state-updates': []
  'dock': []
  'close': []
  'update:position': [position: { x: number, y: number }]
  'update:size': [size: { width: number, height: number }]
}>()

// Position and size state
const position = ref({ x: 100, y: 100 })
const TITLE_BAR_HEIGHT = 40
const size = ref({ width: 800, height: Math.max(400, props.height + TITLE_BAR_HEIGHT) })

const contentHeight = computed(() => Math.max(150, size.value.height - TITLE_BAR_HEIGHT))

// Constraints
const MIN_WIDTH = 400
const MIN_HEIGHT = 300
const SNAP_DISTANCE = 20

// Dragging state
const isDragging = ref(false)
const isResizing = ref(false)
const resizeDirection = ref<string>('')
const dragStart = ref({ x: 0, y: 0 })
const startPos = ref({ x: 0, y: 0 })
const startSize = ref({ width: 0, height: 0 })

const floatingStyle = computed(() => ({
  transform: `translate3d(${position.value.x}px, ${position.value.y}px, 0)`,
  width: `${size.value.width}px`,
  height: `${size.value.height}px`,
}))

const startDrag = (e: MouseEvent | TouchEvent) => {
  if ((e.target as HTMLElement).closest('.title-actions')) return
  
  e.preventDefault()
  isDragging.value = true
  
  const clientX = 'touches' in e ? e.touches[0].clientX : e.clientX
  const clientY = 'touches' in e ? e.touches[0].clientY : e.clientY
  
  dragStart.value = { x: clientX, y: clientY }
  startPos.value = { ...position.value }
  
  document.addEventListener('mousemove', onDrag)
  document.addEventListener('touchmove', onDrag)
  document.addEventListener('mouseup', stopDrag)
  document.addEventListener('touchend', stopDrag)
  
  document.body.style.cursor = 'move'
  document.body.style.userSelect = 'none'
}

const onDrag = (e: MouseEvent | TouchEvent) => {
  if (!isDragging.value) return
  
  const clientX = 'touches' in e ? e.touches[0].clientX : e.clientX
  const clientY = 'touches' in e ? e.touches[0].clientY : e.clientY
  
  let newX = startPos.value.x + (clientX - dragStart.value.x)
  let newY = startPos.value.y + (clientY - dragStart.value.y)
  
  // Clamp to viewport
  const maxX = window.innerWidth - size.value.width
  const maxY = window.innerHeight - size.value.height
  
  newX = Math.max(0, Math.min(newX, maxX))
  newY = Math.max(0, Math.min(newY, maxY))
  
  // Snap to edges
  if (newX < SNAP_DISTANCE) newX = 0
  if (newY < SNAP_DISTANCE) newY = 0
  if (newX > maxX - SNAP_DISTANCE) newX = maxX
  if (newY > maxY - SNAP_DISTANCE) newY = maxY
  
  position.value.x = newX
  position.value.y = newY
}

const stopDrag = () => {
  isDragging.value = false
  
  document.removeEventListener('mousemove', onDrag)
  document.removeEventListener('touchmove', onDrag)
  document.removeEventListener('mouseup', stopDrag)
  document.removeEventListener('touchend', stopDrag)
  
  document.body.style.cursor = ''
  document.body.style.userSelect = ''
  
  emit('update:position', position.value)
}

const startResize = (e: MouseEvent | TouchEvent, direction: string) => {
  e.preventDefault()
  e.stopPropagation()
  
  isResizing.value = true
  resizeDirection.value = direction
  
  const clientX = 'touches' in e ? e.touches[0].clientX : e.clientX
  const clientY = 'touches' in e ? e.touches[0].clientY : e.clientY
  
  dragStart.value = { x: clientX, y: clientY }
  startPos.value = { ...position.value }
  startSize.value = { ...size.value }
  
  document.addEventListener('mousemove', onResize)
  document.addEventListener('touchmove', onResize)
  document.addEventListener('mouseup', stopResize)
  document.addEventListener('touchend', stopResize)
  
  document.body.style.userSelect = 'none'
}

const onResize = (e: MouseEvent | TouchEvent) => {
  if (!isResizing.value) return
  
  const clientX = 'touches' in e ? e.touches[0].clientX : e.clientX
  const clientY = 'touches' in e ? e.touches[0].clientY : e.clientY
  
  const deltaX = clientX - dragStart.value.x
  const deltaY = clientY - dragStart.value.y
  
  let newWidth = startSize.value.width
  let newHeight = startSize.value.height
  let newX = startPos.value.x
  let newY = startPos.value.y
  
  const dir = resizeDirection.value
  
  if (dir.includes('e')) {
    newWidth = Math.max(MIN_WIDTH, startSize.value.width + deltaX)
  }
  if (dir.includes('w')) {
    const minX = startPos.value.x + startSize.value.width - MIN_WIDTH
    newX = Math.min(minX, startPos.value.x + deltaX)
    newWidth = startSize.value.width - (newX - startPos.value.x)
  }
  if (dir.includes('s')) {
    newHeight = Math.max(MIN_HEIGHT, startSize.value.height + deltaY)
  }
  if (dir.includes('n')) {
    const minY = startPos.value.y + startSize.value.height - MIN_HEIGHT
    newY = Math.min(minY, startPos.value.y + deltaY)
    newHeight = startSize.value.height - (newY - startPos.value.y)
  }
  
  // Clamp to viewport
  const maxWidth = window.innerWidth - newX
  const maxHeight = window.innerHeight - newY
  
  newWidth = Math.min(newWidth, maxWidth)
  newHeight = Math.min(newHeight, maxHeight)
  
  position.value.x = newX
  position.value.y = newY
  size.value.width = newWidth
  size.value.height = newHeight
}

const stopResize = () => {
  isResizing.value = false
  resizeDirection.value = ''
  
  document.removeEventListener('mousemove', onResize)
  document.removeEventListener('touchmove', onResize)
  document.removeEventListener('mouseup', stopResize)
  document.removeEventListener('touchend', stopResize)
  
  document.body.style.userSelect = ''
  
  emit('update:size', size.value)
  emit('update:height', Math.max(150, Math.min(600, contentHeight.value)))
}

const handleHeightUpdate = (_newHeight: number) => {
  // For floating window, height update from ResizableLogPanel is ignored
  // (we use the floating window's own height)
}




</script>

<style scoped>
.floating-log-panel {
  position: fixed;
  left: 0;
  top: 0;
  will-change: transform;
  z-index: 1000;
  background: rgb(var(--v-theme-surface));
  border: 1px solid rgba(var(--v-border-color), var(--v-border-opacity));
  border-radius: 8px;
  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.12), 0 2px 8px rgba(0, 0, 0, 0.08);
  display: flex;
  flex-direction: column;
  overflow: hidden;
}

.floating-title-bar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 8px 12px;
  background: rgb(var(--v-theme-primary));
  color: white;
  cursor: move;
  user-select: none;
  border-radius: 8px 8px 0 0;
  min-height: 40px;
}

.title-content {
  display: flex;
  align-items: center;
  font-size: 0.875rem;
  font-weight: 500;
}

.title-text {
  white-space: nowrap;
}

.title-actions {
  display: flex;
  gap: 4px;
}

.title-actions .v-btn {
  color: white;
}

.floating-content {
  flex: 1;
  min-height: 0;
  overflow: hidden;
  display: flex;
  flex-direction: column;
}

/* Resize handles */
.resize-handle {
  position: absolute;
  z-index: 10;
}

.resize-e, .resize-w {
  width: 8px;
  top: 0;
  bottom: 0;
  cursor: ew-resize;
}

.resize-e {
  right: 0;
}

.resize-w {
  left: 0;
}

.resize-n, .resize-s {
  height: 8px;
  left: 0;
  right: 0;
  cursor: ns-resize;
}

.resize-n {
  top: 0;
}

.resize-s {
  bottom: 0;
}

.resize-se, .resize-sw, .resize-ne, .resize-nw {
  width: 16px;
  height: 16px;
}

.resize-se {
  bottom: 0;
  right: 0;
  cursor: nwse-resize;
}

.resize-sw {
  bottom: 0;
  left: 0;
  cursor: nesw-resize;
}

.resize-ne {
  top: 0;
  right: 0;
  cursor: nesw-resize;
}

.resize-nw {
  top: 0;
  left: 0;
  cursor: nwse-resize;
}

.resize-handle:hover {
  background: rgba(var(--v-theme-primary), 0.1);
}
</style>
