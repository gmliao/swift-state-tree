<template>
  <v-card-text style="height: 100%; padding: 4px; display: flex; flex-direction: column; overflow: hidden; background-color: #ffffff;">
    <div style="flex: 1; overflow: hidden; min-height: 0; display: flex; flex-direction: column;">
      <v-alert
        v-if="sortedTableData.length === 0"
        type="info"
        density="compact"
        variant="text"
        class="ma-2"
        style="font-size: 10px; padding: 4px 8px; flex-shrink: 0;"
      >
        {{ (filterKeyword || pathFilter) ? '沒有符合過濾條件的更新記錄' : '尚無狀態更新記錄' }}
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
          <v-text-field
            v-model="filterKeyword"
            label="過濾關鍵字"
            prepend-inner-icon="mdi-filter"
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
  </v-card-text>
</template>

<script setup lang="ts">
import { ref, computed } from 'vue'
import type { StateUpdateEntry } from '@/composables/useWebSocket'

const props = defineProps<{
  stateUpdates: StateUpdateEntry[]
}>()

const pathFilter = ref('')
const filterKeyword = ref('')

interface TableRow {
  id: string
  timestamp: Date
  path: string
  op: string
  value: any
}

const headers = computed(() => [
  { title: '時間', key: 'timestamp', width: '100px', sortable: true },
  { title: '路徑', key: 'path', sortable: true },
  { title: '操作', key: 'op', width: '80px', sortable: true },
  { title: '數值', key: 'value', sortable: false }
])

const tableData = computed<TableRow[]>(() => {
  if (!props.stateUpdates || props.stateUpdates.length === 0) {
    return []
  }
  
  const rows: TableRow[] = []
  
  for (const update of props.stateUpdates) {
    if (!update.patches || update.patches.length === 0) {
      // No patches, just add a summary row
      rows.push({
        id: update.id,
        timestamp: update.timestamp,
        path: '/',
        op: update.type,
        value: update.message || '-'
      })
      continue
    }
    
    // Add a row for each patch
    for (const patch of update.patches) {
      rows.push({
        id: `${update.id}-${patch.path}`,
        timestamp: update.timestamp,
        path: patch.path || '/',
        op: patch.op || update.type,
        value: patch.value !== undefined ? patch.value : null
      })
    }
  }
  
  return rows
})

const sortedTableData = computed(() => {
  let filtered = [...tableData.value]
  
  // Filter by path
  if (pathFilter.value) {
    const filter = pathFilter.value.toLowerCase()
    filtered = filtered.filter(row => 
      row.path.toLowerCase().includes(filter)
    )
  }
  
  // Filter by keyword (op, value, message)
  if (filterKeyword.value) {
    const keyword = filterKeyword.value.toLowerCase()
    filtered = filtered.filter(row => {
      const opMatch = row.op.toLowerCase().includes(keyword)
      const valueMatch = row.value && String(row.value).toLowerCase().includes(keyword)
      return opMatch || valueMatch
    })
  }
  
  // Sort by timestamp (newest first)
  const sorted = filtered.sort((a, b) => 
    b.timestamp.getTime() - a.timestamp.getTime()
  )

  // Keep only newest 3 entries per path to reduce noise
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

const formatTime = (date: Date): string => {
  return date.toLocaleTimeString('zh-TW', {
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    ...({ fractionalSecondDigits: 3 } as any)
  })
}

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
  // Unwrap single-key containers like {"int": {"": 1553}}
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

  // For objects with few props, flatten into label/value rows
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

  // For primitives, still show a single segment
  if (normalized === null || typeof normalized !== 'object') {
    return [{ key: 'value', value: String(normalized) }]
  }

  return []
}
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
</style>
