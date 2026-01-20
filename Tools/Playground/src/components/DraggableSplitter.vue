<template>
  <div
    class="draggable-splitter"
    :class="{ 'is-dragging': isDragging }"
    @mousedown="startDrag"
    @touchstart="startDrag"
  >
    <div class="splitter-handle">
      <v-icon icon="mdi-drag-vertical" size="small" color="medium-emphasis"></v-icon>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref } from 'vue'

const emit = defineEmits<{
  resize: [delta: number]
}>()

const isDragging = ref(false)
let startX = 0

const startDrag = (e: MouseEvent | TouchEvent) => {
  e.preventDefault()
  isDragging.value = true
  
  const clientX = 'touches' in e ? e.touches[0].clientX : e.clientX
  startX = clientX
  
  document.addEventListener('mousemove', onDrag)
  document.addEventListener('touchmove', onDrag)
  document.addEventListener('mouseup', stopDrag)
  document.addEventListener('touchend', stopDrag)
  
  document.body.style.cursor = 'col-resize'
  document.body.style.userSelect = 'none'
}

const onDrag = (e: MouseEvent | TouchEvent) => {
  if (!isDragging.value) return
  
  const clientX = 'touches' in e ? e.touches[0].clientX : e.clientX
  const delta = clientX - startX
  startX = clientX
  
  emit('resize', delta)
}

const stopDrag = () => {
  isDragging.value = false
  
  document.removeEventListener('mousemove', onDrag)
  document.removeEventListener('touchmove', onDrag)
  document.removeEventListener('mouseup', stopDrag)
  document.removeEventListener('touchend', stopDrag)
  
  document.body.style.cursor = ''
  document.body.style.userSelect = ''
}
</script>

<style scoped>
.draggable-splitter {
  width: 8px;
  min-width: 8px;
  background: transparent;
  cursor: col-resize;
  position: relative;
  display: flex;
  align-items: center;
  justify-content: center;
  transition: background-color 0.2s;
  flex-shrink: 0;
}

.draggable-splitter:hover,
.draggable-splitter.is-dragging {
  background: rgba(var(--v-theme-primary), 0.08);
}

.splitter-handle {
  display: flex;
  align-items: center;
  justify-content: center;
  width: 100%;
  height: 48px;
  border-radius: 4px;
  transition: background-color 0.2s;
}

.draggable-splitter:hover .splitter-handle,
.draggable-splitter.is-dragging .splitter-handle {
  background: rgba(var(--v-theme-primary), 0.12);
}

.draggable-splitter.is-dragging {
  background: rgba(var(--v-theme-primary), 0.12);
}
</style>
