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
        <v-icon :icon="getIcon(item.type)" :color="getColor(item.type, item.syncPolicy)"></v-icon>
      </template>
      <template v-slot:title="{ item }">
        <div style="display: flex; align-items: center; gap: 8px;">
          <span>{{ item.name }}</span>
          <v-chip
            v-if="item.syncPolicy"
            :color="getPolicyColor(item.syncPolicy)"
            size="x-small"
            variant="flat"
            style="font-size: 0.7rem; height: 18px;"
          >
            {{ item.syncPolicy }}
          </v-chip>
          <v-chip
            v-if="item.nodeKind"
            :color="getNodeKindColor(item.nodeKind)"
            size="x-small"
            variant="flat"
            style="font-size: 0.7rem; height: 18px;"
          >
            {{ item.nodeKind }}
          </v-chip>
        </div>
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
  syncPolicy?: string
  nodeKind?: string
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

  // Get the root state schema from the first land definition
  const rootStateSchema = getRootStateSchema()

  return Object.entries(props.state).map(([key, value]) => {
    const fieldSchema = rootStateSchema?.properties?.[key]
    return buildTreeItem(key, value, 0, '', fieldSchema)
  })
})

const resolveRef = (ref: string | { $ref: string } | undefined): any => {
  if (!ref) return null
  if (typeof ref === 'string') {
    const refName = ref.replace('#/defs/', '').replace('defs/', '')
    return props.schema?.defs[refName] || null
  }
  if (ref.$ref) {
    const refName = ref.$ref.replace('#/defs/', '').replace('defs/', '')
    return props.schema?.defs[refName] || null
  }
  return null
}

const getRootStateSchema = () => {
  if (!props.schema) return null
  
  // Get the first land definition to find the root state type
  const landKeys = Object.keys(props.schema.lands)
  if (landKeys.length === 0) return null
  
  const firstLand = props.schema.lands[landKeys[0]]
  if (!firstLand?.stateType) return null
  
  // Get the state type schema from defs
  const stateTypeRef = firstLand.stateType
  const resolved = resolveRef(stateTypeRef)
  return resolved
}

const getFieldSchema = (path: string[], currentSchema: any): any => {
  if (!currentSchema || path.length === 0) return currentSchema
  
  const [first, ...rest] = path
  
  // Check if it's a property
  if (currentSchema.properties && currentSchema.properties[first]) {
    return getFieldSchema(rest, currentSchema.properties[first])
  }
  
  // Check if it's an array item
  if (currentSchema.items && first.match(/^\[\d+\]$/)) {
    return getFieldSchema(rest, currentSchema.items)
  }
  
  // Check if it's an additionalProperties (dictionary)
  if (currentSchema.additionalProperties && typeof currentSchema.additionalProperties === 'object') {
    return getFieldSchema(rest, currentSchema.additionalProperties)
  }
  
  return null
}

const buildTreeItem = (key: string, value: any, depth: number, path: string = '', fieldSchema?: any): TreeItem => {
  // Use stable ID based on path (not random) to preserve expand state
  const itemPath = path ? `${path}.${key}` : key
  const id = itemPath
  
  // Resolve $ref if present
  if (fieldSchema?.$ref) {
    fieldSchema = resolveRef(fieldSchema.$ref) || fieldSchema
  }
  
  // Extract schema metadata
  const stateTreeMeta = fieldSchema?.['x-stateTree']
  const syncPolicy = stateTreeMeta?.sync?.policy
  const nodeKind = stateTreeMeta?.nodeKind
  const fieldType = fieldSchema?.type || (typeof value === 'object' && value !== null ? (Array.isArray(value) ? 'array' : 'object') : typeof value)
  
  if (value === null || value === undefined) {
    return {
      id,
      name: `${key}: null`,
      value: null,
      type: 'null',
      syncPolicy,
      nodeKind
    }
  }

  if (Array.isArray(value)) {
    let itemSchema = fieldSchema?.items
    // Resolve $ref in items schema
    if (itemSchema) {
      itemSchema = resolveRef(itemSchema) || itemSchema
    }
    return {
      id,
      name: `${key} (Array[${value.length}])`,
      type: 'array',
      syncPolicy,
      nodeKind,
      children: value.map((item, index) => {
        // For arrays, try to get item schema
        return buildTreeItem(`[${index}]`, item, depth + 1, itemPath, itemSchema)
      })
    }
  }

  if (typeof value === 'object') {
    // Check if it's a dictionary (object with string keys)
    const isDictionary = !Array.isArray(value) && Object.keys(value).length > 0 && 
                         Object.keys(value).every(k => typeof k === 'string')
    
    // Get nested schema for object properties
    let nestedSchema = fieldSchema?.properties
    let dictItemSchema: any = null
    
    // Handle additionalProperties (dictionary)
    if (fieldSchema?.additionalProperties) {
      if (typeof fieldSchema.additionalProperties === 'object') {
        dictItemSchema = resolveRef(fieldSchema.additionalProperties) || fieldSchema.additionalProperties
      }
    }
    
    // Resolve $ref in nested schema properties
    if (nestedSchema) {
      const resolved: Record<string, any> = {}
      for (const [propKey, propSchema] of Object.entries(nestedSchema)) {
        resolved[propKey] = resolveRef(propSchema as any) || propSchema
      }
      nestedSchema = resolved
    }
    
    return {
      id,
      name: `${key} (Object${isDictionary ? ' (Dict)' : ''})`,
      type: 'object',
      syncPolicy,
      nodeKind,
      children: Object.entries(value).map(([k, v]) => {
        // For dictionaries, use dictItemSchema; for regular objects, use nestedSchema[k]
        const childSchema = dictItemSchema || nestedSchema?.[k]
        return buildTreeItem(k, v, depth + 1, itemPath, childSchema)
      })
    }
  }

  return {
    id,
    name: `${key}: ${String(value)}`,
    value,
    type: typeof value,
    syncPolicy,
    nodeKind
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

const getColor = (type?: string, syncPolicy?: string): string => {
  // If there's a sync policy, use policy-based colors
  if (syncPolicy) {
    switch (syncPolicy) {
      case 'broadcast': return 'blue'
      case 'perPlayer': return 'green'
      case 'perPlayerSlice': return 'teal'
      case 'serverOnly': return 'orange'
      case 'masked': return 'purple'
      case 'custom': return 'pink'
      default: return 'grey'
    }
  }
  
  // Fall back to type-based colors
  switch (type) {
    case 'object': return 'primary'
    case 'array': return 'secondary'
    case 'string': return 'success'
    case 'number': return 'info'
    case 'boolean': return 'warning'
    default: return 'grey'
  }
}

const getPolicyColor = (policy: string): string => {
  switch (policy) {
    case 'broadcast': return 'blue'
    case 'perPlayer': return 'green'
    case 'perPlayerSlice': return 'teal'
    case 'serverOnly': return 'orange'
    case 'masked': return 'purple'
    case 'custom': return 'pink'
    default: return 'grey'
  }
}

const getNodeKindColor = (nodeKind: string): string => {
  switch (nodeKind) {
    case 'StateNode': return 'indigo'
    case 'StateProtocol': return 'cyan'
    default: return 'grey-darken-1'
  }
}


</script>

<style scoped>
</style>
