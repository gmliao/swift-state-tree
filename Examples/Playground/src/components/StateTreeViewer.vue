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
      
      <!-- State Update History Panel -->
      <v-divider class="my-2"></v-divider>
      <v-expansion-panels variant="accordion" density="compact">
        <v-expansion-panel>
          <v-expansion-panel-title>
            <v-icon icon="mdi-update" class="mr-2"></v-icon>
            狀態更新歷史 ({{ sortedTableData.length }} 筆)
          </v-expansion-panel-title>
          <v-expansion-panel-text>
            <!-- Filter Inputs -->
            <v-text-field
              v-model="pathFilter"
              label="過濾路徑名稱"
              prepend-inner-icon="mdi-folder-search"
              variant="outlined"
              density="compact"
              clearable
              class="mb-2"
            ></v-text-field>
            
            <v-text-field
              v-model="filterKeyword"
              label="過濾關鍵字 (操作、數值)"
              prepend-inner-icon="mdi-filter"
              variant="outlined"
              density="compact"
              clearable
              class="mb-2"
            ></v-text-field>
            
            <!-- Table -->
            <div class="table-container">
              <table class="updates-table">
                <thead>
                  <tr>
                    <th @click="sortBy('path')" class="sortable">
                      Path
                      <v-icon 
                        v-if="sortColumn === 'path'" 
                        :icon="sortDirection === 'asc' ? 'mdi-arrow-up' : 'mdi-arrow-down'"
                        size="small"
                        class="ml-1"
                      ></v-icon>
                    </th>
                    <th @click="sortBy('op')" class="sortable">
                      Op
                      <v-icon 
                        v-if="sortColumn === 'op'" 
                        :icon="sortDirection === 'asc' ? 'mdi-arrow-up' : 'mdi-arrow-down'"
                        size="small"
                        class="ml-1"
                      ></v-icon>
                    </th>
                    <th @click="sortBy('value')" class="sortable">
                      Value
                      <v-icon 
                        v-if="sortColumn === 'value'" 
                        :icon="sortDirection === 'asc' ? 'mdi-arrow-up' : 'mdi-arrow-down'"
                        size="small"
                        class="ml-1"
                      ></v-icon>
                    </th>
                    <th @click="sortBy('time')" class="sortable">
                      Time
                      <v-icon 
                        v-if="sortColumn === 'time'" 
                        :icon="sortDirection === 'asc' ? 'mdi-arrow-up' : 'mdi-arrow-down'"
                        size="small"
                        class="ml-1"
                      ></v-icon>
                    </th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    v-for="(row, index) in sortedTableData"
                    :key="`${row.updateId}-${index}`"
                    class="table-row"
                  >
                    <td class="path-cell">{{ row.path }}</td>
                    <td class="op-cell">
                      <v-chip 
                        size="x-small" 
                        :color="getPatchColor(row.op)" 
                        variant="flat"
                      >
                        {{ row.op }}
                      </v-chip>
                    </td>
                    <td class="value-cell">
                      <span v-if="row.value !== undefined && row.value !== null" class="value-text">
                        {{ formatPatchValue(row.value) }}
                      </span>
                      <span v-else class="value-empty">-</span>
                    </td>
                    <td class="time-cell">{{ formatTime(row.time) }}</td>
                  </tr>
                </tbody>
              </table>
              
              <v-alert
                v-if="sortedTableData.length === 0"
                type="info"
                density="compact"
                class="mt-2"
              >
                {{ (filterKeyword || pathFilter) ? '沒有符合過濾條件的更新記錄' : '尚無狀態更新記錄' }}
              </v-alert>
            </div>
          </v-expansion-panel-text>
        </v-expansion-panel>
      </v-expansion-panels>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import type { Schema } from '@/types'
import type { StateUpdateEntry } from '@/composables/useWebSocket'

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
  stateUpdates?: StateUpdateEntry[]
}>()

// Filter keywords
const filterKeyword = ref('')
const pathFilter = ref('')

// Sort state
const sortColumn = ref<'path' | 'op' | 'value' | 'time' | null>(null)
const sortDirection = ref<'asc' | 'desc'>('desc')

// Table row data structure
interface TableRow {
  updateId: string
  path: string
  op: string
  value: any
  time: Date
  updateType: string
}

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

const formatTime = (date: Date): string => {
  return date.toLocaleTimeString('zh-TW', {
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit'
  }) + '.' + date.getMilliseconds().toString().padStart(3, '0')
}


// 將所有更新展平為表格行數據（每個 path 保留最新的 3 筆更新）
const tableData = computed((): TableRow[] => {
  if (!props.stateUpdates || props.stateUpdates.length === 0) {
    return []
  }
  
  // 使用 Map 以單一路徑作為 key，每個路徑保留最新的 3 筆更新
  const pathUpdateMap = new Map<string, StateUpdateEntry[]>()
  
  // 從最新到最舊遍歷
  for (let i = props.stateUpdates.length - 1; i >= 0; i--) {
    const update = props.stateUpdates[i]
    
    // snapshot 和 firstSync 也參與，但會特殊處理
    if (update.type === 'snapshot' || update.type === 'firstSync') {
      // 對於 snapshot/firstSync，如果有 patches，也加入
      if (update.patches && update.patches.length > 0) {
        for (const patch of update.patches) {
          const pathParts = patch.path.split('/').filter(p => p !== '')
          const path = pathParts.length > 0 ? pathParts[0] : patch.path
          
          if (!pathUpdateMap.has(path)) {
            pathUpdateMap.set(path, [])
          }
          const updates = pathUpdateMap.get(path)!
          if (updates.length < 3) {
            updates.push(update)
          }
        }
      }
      continue
    }
    
    // 為每個受影響的路徑分別記錄更新
    if (update.affectedPaths && update.affectedPaths.length > 0) {
      for (const path of update.affectedPaths) {
        if (!pathUpdateMap.has(path)) {
          pathUpdateMap.set(path, [])
        }
        const updates = pathUpdateMap.get(path)!
        // 每個路徑只保留最新的 3 筆
        if (updates.length < 3) {
          updates.push(update)
        }
      }
    } else {
      // 沒有路徑信息，使用 id 作為 key
      const key = update.id
      if (!pathUpdateMap.has(key)) {
        pathUpdateMap.set(key, [])
      }
      const updates = pathUpdateMap.get(key)!
      if (updates.length < 3) {
        updates.push(update)
      }
    }
  }
  
  // 將更新轉換為表格行（每個 patch 一行）
  const rows: TableRow[] = []
  
  for (const [path, updates] of pathUpdateMap.entries()) {
    for (const update of updates) {
      if (update.patches && update.patches.length > 0) {
        // 只處理與該 path 相關的 patches
        const relevantPatches = update.patches.filter(p => {
          const patchPathParts = p.path.split('/').filter(part => part !== '')
          const patchPath = patchPathParts.length > 0 ? patchPathParts[0] : p.path
          return patchPath === path
        })
        
        for (const patch of relevantPatches) {
          // Use full path instead of just first-level path for better clarity
          // But still group by first-level path for filtering
          rows.push({
            updateId: update.id,
            path: patch.path, // Use full path instead of just first-level
            op: patch.op,
            value: patch.value,
            time: update.timestamp,
            updateType: update.type
          })
        }
      }
    }
  }
  
  return rows
})

// 過濾表格數據
const filteredTableData = computed((): TableRow[] => {
  let data = tableData.value
  
  // Path name filter
  if (pathFilter.value) {
    const pathKeyword = pathFilter.value.toLowerCase()
    data = data.filter(row => row.path.toLowerCase().includes(pathKeyword))
  }
  
  // General keyword filter
  if (filterKeyword.value) {
    const keyword = filterKeyword.value.toLowerCase()
    data = data.filter(row => {
      // 過濾 op
      if (row.op.toLowerCase().includes(keyword)) return true
      // 過濾 value
      if (row.value !== undefined && row.value !== null) {
        const valueStr = JSON.stringify(row.value).toLowerCase()
        if (valueStr.includes(keyword)) return true
      }
      return false
    })
  }
  
  return data
})

// 排序表格數據
const sortedTableData = computed((): TableRow[] => {
  if (!sortColumn.value) {
    // 預設按時間降序（最新的在前）
    return [...filteredTableData.value].sort((a, b) => 
      b.time.getTime() - a.time.getTime()
    )
  }
  
  const data = [...filteredTableData.value]
  
  data.sort((a, b) => {
    let comparison = 0
    
    switch (sortColumn.value) {
      case 'path':
        comparison = a.path.localeCompare(b.path)
        break
      case 'op':
        comparison = a.op.localeCompare(b.op)
        break
      case 'value':
        const aVal = a.value !== undefined && a.value !== null ? JSON.stringify(a.value) : ''
        const bVal = b.value !== undefined && b.value !== null ? JSON.stringify(b.value) : ''
        comparison = aVal.localeCompare(bVal)
        break
      case 'time':
        comparison = a.time.getTime() - b.time.getTime()
        break
    }
    
    return sortDirection.value === 'asc' ? comparison : -comparison
  })
  
  return data
})

// 排序處理
const sortBy = (column: 'path' | 'op' | 'value' | 'time') => {
  if (sortColumn.value === column) {
    // 切換排序方向
    sortDirection.value = sortDirection.value === 'asc' ? 'desc' : 'asc'
  } else {
    // 新的排序欄位
    sortColumn.value = column
    sortDirection.value = 'asc'
  }
}

// 格式化 patch 數值顯示
const formatPatchValue = (value: any): string => {
  if (value === null) return 'null'
  if (value === undefined) return 'undefined'
  
  const str = JSON.stringify(value)
  if (str.length > 100) {
    return str.slice(0, 100) + '...'
  }
  return str
}

const getPatchColor = (op: string): string => {
  switch (op) {
    case 'add': return 'success'
    case 'replace': return 'info'
    case 'remove': return 'error'
    default: return 'grey'
  }
}

</script>

<style scoped>
.table-container {
  max-height: 400px;
  overflow: auto;
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 4px;
}

.updates-table {
  width: 100%;
  border-collapse: collapse;
  font-size: 11px;
  background: rgba(0, 0, 0, 0.2);
}

.updates-table thead {
  position: sticky;
  top: 0;
  background: rgba(30, 30, 30, 0.95);
  z-index: 1;
}

.updates-table th {
  padding: 8px;
  text-align: left;
  border-bottom: 2px solid rgba(255, 255, 255, 0.2);
  color: rgba(255, 255, 255, 0.9);
  font-weight: 500;
  cursor: pointer;
  user-select: none;
  white-space: nowrap;
}

.updates-table th.sortable:hover {
  background: rgba(255, 255, 255, 0.1);
}

.updates-table td {
  padding: 6px 8px;
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);
}

.updates-table tbody tr:hover {
  background: rgba(255, 255, 255, 0.05);
}

.path-cell {
  font-family: monospace;
  color: rgba(255, 255, 255, 0.9);
  font-weight: 500;
  min-width: 150px;
  max-width: 300px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.op-cell {
  text-align: center;
  min-width: 80px;
}

.value-cell {
  max-width: 300px;
  overflow: hidden;
  text-overflow: ellipsis;
}

.value-text {
  font-family: monospace;
  color: rgba(255, 255, 255, 0.8);
  font-size: 10px;
  word-break: break-all;
  display: block;
  max-width: 100%;
}

.value-empty {
  color: rgba(255, 255, 255, 0.4);
  font-style: italic;
}

.time-cell {
  color: rgba(255, 255, 255, 0.6);
  font-size: 10px;
  white-space: nowrap;
  min-width: 120px;
}

.patches-list {
  max-height: 200px;
  overflow-y: auto;
  font-size: 10px;
}

.patch-entry {
  padding: 4px 0;
  border-bottom: 1px solid rgba(255, 255, 255, 0.05);
  display: flex;
  align-items: center;
  flex-wrap: wrap;
}

.patch-entry:last-child {
  border-bottom: none;
}

.patch-path {
  color: rgba(255, 255, 255, 0.8);
  font-family: monospace;
  margin-right: 8px;
  font-size: 10px;
}

.patch-value {
  color: rgba(255, 255, 255, 0.6);
  font-family: monospace;
  font-size: 9px;
  word-break: break-all;
}

.patch-more {
  color: rgba(255, 255, 255, 0.5);
  font-size: 9px;
  padding: 4px 0;
  text-align: center;
  font-style: italic;
}
</style>
