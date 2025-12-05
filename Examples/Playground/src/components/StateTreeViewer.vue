<template>
  <div>
    <v-alert
      v-if="!state || Object.keys(state).length === 0"
      type="info"
      density="compact"
    >
      等待狀態更新...
    </v-alert>
    <v-treeview
      v-else
      :items="treeItems"
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
</template>

<script setup lang="ts">
import { computed } from 'vue'
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

const treeItems = computed((): TreeItem[] => {
  if (!props.state || Object.keys(props.state).length === 0) {
    return []
  }

  return Object.entries(props.state).map(([key, value]) => {
    return buildTreeItem(key, value, 0)
  })
})

const buildTreeItem = (key: string, value: any, depth: number): TreeItem => {
  const id = `${key}-${depth}-${Math.random().toString(36).substr(2, 9)}`
  
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
        buildTreeItem(`[${index}]`, item, depth + 1)
      )
    }
  }

  if (typeof value === 'object') {
    return {
      id,
      name: `${key} (Object)`,
      type: 'object',
      children: Object.entries(value).map(([k, v]) => 
        buildTreeItem(k, v, depth + 1)
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
