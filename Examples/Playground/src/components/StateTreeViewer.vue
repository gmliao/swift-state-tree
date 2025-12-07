<template>
  <div>
    <v-alert
      v-if="!state || Object.keys(state).length === 0"
      type="info"
      density="compact"
    >
      等待狀態更新...
    </v-alert>
    <div v-else>
    <v-treeview
      :items="treeItems"
        :key="treeKey"
      activatable
      item-title="name"
      item-value="id"
      item-children="children"
      density="compact"
    >
      <template v-slot:prepend="{ item }">
        <v-icon :icon="getIcon(item.type)" :color="getColor(item.type)"></v-icon>
      </template>
    </v-treeview>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import type { Schema } from '@/types'

interface TreeItem {
  id: string
  name: string
  value?: any
  type?: string
  children?: TreeItem[]
}

const props = defineProps<{
  state: Record<string, any>
  schema: Schema | null
}>()

// Use a stable key that only changes when state structure changes significantly
// This helps preserve expand state in v-treeview
const treeKey = ref(0)

// Watch for major state structure changes (new top-level keys)
watch(() => props.state, (newState, oldState) => {
  if (!oldState || Object.keys(oldState).length === 0) {
    // First load, increment key to trigger initial render
    treeKey.value++
  } else {
    // Check if top-level keys changed (not just values)
    const oldKeys = new Set(Object.keys(oldState || {}))
    const newKeys = new Set(Object.keys(newState || {}))
    const keysChanged = oldKeys.size !== newKeys.size || 
      [...newKeys].some(key => !oldKeys.has(key))
    
    if (keysChanged) {
      // Only increment key if structure changed, not just values
      treeKey.value++
    }
  }
}, { deep: false }) // Only watch top-level changes

const treeItems = computed((): TreeItem[] => {
  if (!props.state || Object.keys(props.state).length === 0) {
    return []
  }

  return Object.entries(props.state).map(([key, value]) => {
    return buildTreeItem(key, value, 0)
  })
})

const buildTreeItem = (key: string, value: any, depth: number, path: string = ''): TreeItem => {
  // Use stable ID based on path (not random) to preserve expand state
  const itemPath = path ? `${path}.${key}` : key
  const id = itemPath
  
  if (value === null || value === undefined) {
    return {
      id,
      name: `${key}: null`,
      value: null,
      type: 'null'
    }
  }

  if (Array.isArray(value)) {
    return {
      id,
      name: `${key} (Array[${value.length}])`,
      type: 'array',
      children: value.map((item, index) => 
        buildTreeItem(`[${index}]`, item, depth + 1, itemPath)
      )
    }
  }

  if (typeof value === 'object') {
    return {
      id,
      name: `${key} (Object)`,
      type: 'object',
      children: Object.entries(value).map(([k, v]) => 
        buildTreeItem(k, v, depth + 1, itemPath)
      )
    }
  }

  return {
    id,
    name: `${key}: ${String(value)}`,
    value,
    type: typeof value
  }
}

const getIcon = (type?: string): string => {
  switch (type) {
    case 'object': return 'mdi-folder'
    case 'array': return 'mdi-format-list-bulleted'
    case 'string': return 'mdi-format-text'
    case 'number': return 'mdi-numeric'
    case 'boolean': return 'mdi-toggle-switch'
    case 'null': return 'mdi-null'
    default: return 'mdi-file'
  }
}

const getColor = (type?: string): string => {
  switch (type) {
    case 'object': return 'primary'
    case 'array': return 'secondary'
    case 'string': return 'success'
    case 'number': return 'info'
    case 'boolean': return 'warning'
    default: return 'grey'
  }
}


</script>

<style scoped>
</style>
