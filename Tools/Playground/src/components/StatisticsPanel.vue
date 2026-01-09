<template>
  <v-card-text class="statistics-panel">
    <div v-if="!connected" class="text-center pa-4">
      <v-icon icon="mdi-information" size="large" class="mb-2"></v-icon>
      <div>請先連線以查看統計資訊</div>
    </div>

    <div v-else>
      <!-- Real-time Statistics -->
      <v-card variant="outlined" class="mb-4">
        <v-card-title class="text-subtitle-1">
          <v-icon icon="mdi-chart-line" size="small" class="mr-2"></v-icon>
          即時統計
        </v-card-title>
        <v-card-text>
          <v-row dense>
            <v-col cols="6" md="3">
              <v-card variant="flat" color="primary" class="stat-card">
                <v-card-text class="text-center pa-2">
                  <div class="text-caption text-white">每秒封包數</div>
                  <div class="text-h6 text-white font-weight-bold">
                    {{ packetsPerSecond.toFixed(1) }}<span class="text-caption ml-1">個/s</span>
                  </div>
                </v-card-text>
              </v-card>
            </v-col>
            <v-col cols="6" md="3">
              <v-card variant="flat" color="success" class="stat-card">
                <v-card-text class="text-center pa-2">
                  <div class="text-caption text-white">每秒流量</div>
                  <div class="text-h6 text-white font-weight-bold">
                    {{ formatBytes(bytesPerSecond) }}<span class="text-caption ml-1">/s</span>
                  </div>
                </v-card-text>
              </v-card>
            </v-col>
            <v-col cols="6" md="3">
              <v-card variant="flat" color="info" class="stat-card">
                <v-card-text class="text-center pa-2">
                  <div class="text-caption text-white">累計封包</div>
                  <div class="text-h6 text-white font-weight-bold">
                    {{ totalPackets }}<span class="text-caption ml-1">個</span>
                  </div>
                </v-card-text>
              </v-card>
            </v-col>
            <v-col cols="6" md="3">
              <v-card variant="flat" color="warning" class="stat-card">
                <v-card-text class="text-center pa-2">
                  <div class="text-caption text-white">累計流量</div>
                  <div class="text-h6 text-white font-weight-bold">{{ formatBytes(totalBytes) }}</div>
                </v-card-text>
              </v-card>
            </v-col>
          </v-row>
        </v-card-text>
      </v-card>

      <!-- Traffic Chart -->
      <v-card variant="outlined" class="mb-4">
        <v-card-title class="text-subtitle-1">
          <v-icon icon="mdi-chart-timeline-variant" size="small" class="mr-2"></v-icon>
          流量圖表（最近 60 秒）
          <v-btn
            icon="mdi-refresh"
            size="x-small"
            variant="text"
            density="compact"
            @click="resetStatistics"
            title="重置統計"
            class="ml-2"
            style="min-width: auto; width: auto;"
          ></v-btn>
          <v-spacer></v-spacer>
        </v-card-title>
        <v-card-text>
          <div class="chart-container">
            <canvas ref="chartCanvas" class="traffic-chart"></canvas>
          </div>
        </v-card-text>
      </v-card>

      <!-- Detailed Statistics Table -->
      <v-card variant="outlined">
        <v-card-title class="text-subtitle-1">
          <v-icon icon="mdi-table" size="small" class="mr-2"></v-icon>
          詳細統計
        </v-card-title>
        <v-card-text>
          <v-data-table
            :items="statisticsTable"
            :headers="statisticsHeaders"
            density="compact"
            hide-default-footer
            class="statistics-table"
          >
            <template v-slot:item.value="{ item }">
              <code>{{ item.value }}</code>
            </template>
          </v-data-table>
        </v-card-text>
      </v-card>
    </div>
  </v-card-text>
</template>

<script setup lang="ts">
import { ref, computed, watch, onMounted, onUnmounted, nextTick } from 'vue'
import type { StateUpdateEntry } from '@/composables/useWebSocket'

const props = defineProps<{
  connected: boolean
  stateUpdates: StateUpdateEntry[]
}>()

// Statistics data
const totalPackets = ref(0)
const totalBytes = ref(0)
const packetsPerSecond = ref(0)
const bytesPerSecond = ref(0)

// Time series data for chart (last 60 seconds)
const timeSeriesData = ref<Array<{ time: number; packets: number; bytes: number }>>([])
const chartCanvas = ref<HTMLCanvasElement | null>(null)

// Track statistics
let lastTotalPackets = 0
let lastTotalBytes = 0
let lastSecondTimestamp = Date.now()
let updateInterval: number | null = null
let statsUpdateInterval: number | null = null

// Calculate packet size (estimate)
const estimatePacketSize = (update: StateUpdateEntry): number => {
  if (!update.patches || update.patches.length === 0) {
    return 100 // Base size for empty updates
  }
  
  // Estimate: each patch is roughly 200-500 bytes depending on value size
  let estimatedSize = 100 // Base overhead
  for (const patch of update.patches) {
    const pathSize = (patch.path || '').length
    const valueSize = patch.value ? JSON.stringify(patch.value).length : 0
    estimatedSize += 50 + pathSize + valueSize // Rough estimate
  }
  
  return estimatedSize
}

// Update total statistics when state updates change
watch(() => props.stateUpdates, (updates) => {
  if (!updates || updates.length === 0) {
    totalPackets.value = 0
    totalBytes.value = 0
    return
  }
  
  // Update total counts
  totalPackets.value = updates.length
  
  // Recalculate total bytes from all updates
  totalBytes.value = updates.reduce((sum, update) => {
    return sum + estimatePacketSize(update)
  }, 0)
}, { deep: true })

// Calculate per-second statistics every second
const calculatePerSecondStats = () => {
  const now = Date.now()
  const currentSecond = Math.floor(now / 1000)
  const lastSecond = Math.floor(lastSecondTimestamp / 1000)
  
  if (currentSecond > lastSecond) {
    // Calculate packets and bytes in the last second
    const packetsInLastSecond = totalPackets.value - lastTotalPackets
    const bytesInLastSecond = totalBytes.value - lastTotalBytes
    
    // Update per-second values
    packetsPerSecond.value = packetsInLastSecond
    bytesPerSecond.value = bytesInLastSecond
    
    // Add to time series
    timeSeriesData.value.push({
      time: now,
      packets: packetsInLastSecond,
      bytes: bytesInLastSecond
    })
    
    // Keep only last 60 seconds
    const cutoffTime = now - 60000
    timeSeriesData.value = timeSeriesData.value.filter(d => d.time >= cutoffTime)
    
    // Update tracking variables
    lastTotalPackets = totalPackets.value
    lastTotalBytes = totalBytes.value
    lastSecondTimestamp = now
  } else if (currentSecond === lastSecond) {
    // Same second, calculate current rate (for real-time display)
    const elapsed = (now - lastSecondTimestamp) / 1000
    if (elapsed > 0) {
      const packetsInCurrentSecond = totalPackets.value - lastTotalPackets
      const bytesInCurrentSecond = totalBytes.value - lastTotalBytes
      
      // Show current second's rate (will be finalized at end of second)
      packetsPerSecond.value = packetsInCurrentSecond
      bytesPerSecond.value = bytesInCurrentSecond
    }
  }
}

// Format bytes to human readable
const formatBytes = (bytes: number): string => {
  if (bytes === 0) return '0 B'
  const k = 1024
  const sizes = ['B', 'KB', 'MB', 'GB']
  const i = Math.floor(Math.log(bytes) / Math.log(k))
  return `${(bytes / Math.pow(k, i)).toFixed(2)} ${sizes[i]}`
}

// Format bytes for chart labels (shorter format)
const formatBytesShort = (bytes: number): string => {
  if (bytes === 0) return '0'
  const k = 1024
  const sizes = ['B', 'K', 'M', 'G']
  const i = Math.floor(Math.log(bytes) / Math.log(k))
  const value = bytes / Math.pow(k, i)
  if (value >= 100) {
    return `${value.toFixed(0)}${sizes[i]}`
  } else if (value >= 10) {
    return `${value.toFixed(1)}${sizes[i]}`
  } else {
    return `${value.toFixed(2)}${sizes[i]}`
  }
}

// Statistics table
const statisticsHeaders = [
  { title: '項目', key: 'label' },
  { title: '數值', key: 'value' }
]

const statisticsTable = computed(() => [
  { label: '連線時間', value: formatUptime() },
  { label: '平均每秒封包數', value: averagePacketsPerSecond.value.toFixed(2) },
  { label: '平均每秒流量', value: formatBytes(averageBytesPerSecond.value) + '/s' },
  { label: '最大每秒封包數', value: maxPacketsPerSecond.value.toString() },
  { label: '最大每秒流量', value: formatBytes(maxBytesPerSecond.value) + '/s' },
  { label: '總封包數', value: totalPackets.value.toString() },
  { label: '總流量', value: formatBytes(totalBytes.value) }
])

const startTime = ref(Date.now())

const formatUptime = (): string => {
  const uptime = Math.floor((Date.now() - startTime.value) / 1000)
  const hours = Math.floor(uptime / 3600)
  const minutes = Math.floor((uptime % 3600) / 60)
  const seconds = uptime % 60
  if (hours > 0) {
    return `${hours}h ${minutes}m ${seconds}s`
  } else if (minutes > 0) {
    return `${minutes}m ${seconds}s`
  } else {
    return `${seconds}s`
  }
}

const averagePacketsPerSecond = computed(() => {
  if (timeSeriesData.value.length === 0) return 0
  const total = timeSeriesData.value.reduce((sum, d) => sum + d.packets, 0)
  return total / timeSeriesData.value.length
})

const averageBytesPerSecond = computed(() => {
  if (timeSeriesData.value.length === 0) return 0
  const total = timeSeriesData.value.reduce((sum, d) => sum + d.bytes, 0)
  return total / timeSeriesData.value.length
})

const maxPacketsPerSecond = computed(() => {
  if (timeSeriesData.value.length === 0) return 0
  return Math.max(...timeSeriesData.value.map(d => d.packets))
})

const maxBytesPerSecond = computed(() => {
  if (timeSeriesData.value.length === 0) return 0
  return Math.max(...timeSeriesData.value.map(d => d.bytes))
})

// Draw chart
const drawChart = () => {
  if (!chartCanvas.value) return
  
  const canvas = chartCanvas.value
  const ctx = canvas.getContext('2d')
  if (!ctx) return
  
  // Get container dimensions
  const container = canvas.parentElement
  if (!container) return
  
  const rect = container.getBoundingClientRect()
  const displayWidth = Math.max(100, rect.width - 32) // Account for padding
  const displayHeight = 200
  
  // Handle device pixel ratio for crisp rendering
  const dpr = window.devicePixelRatio || 1
  
  // Calculate actual pixel dimensions
  const actualWidth = Math.floor(displayWidth * dpr)
  const actualHeight = Math.floor(displayHeight * dpr)
  
  // Only update canvas size if it changed (avoid unnecessary resets)
  if (canvas.width !== actualWidth || canvas.height !== actualHeight) {
    // Set CSS size first
    canvas.style.width = `${displayWidth}px`
    canvas.style.height = `${displayHeight}px`
    
    // Set actual size in memory (scaled for device pixel ratio)
    canvas.width = actualWidth
    canvas.height = actualHeight
    
    // Reset transform after size change
    ctx.setTransform(1, 0, 0, 1, 0, 0)
    ctx.scale(dpr, dpr)
  }
  
  const width = displayWidth
  const height = displayHeight
  
  // Clear canvas
  ctx.clearRect(0, 0, width, height)
  
  if (timeSeriesData.value.length === 0) {
    ctx.fillStyle = '#999'
    ctx.font = '14px sans-serif'
    ctx.textAlign = 'center'
    ctx.fillText('尚無數據', width / 2, height / 2)
    return
  }
  
  // Find max values for scaling
  const maxPackets = Math.max(1, ...timeSeriesData.value.map(d => d.packets))
  const maxBytes = Math.max(1, ...timeSeriesData.value.map(d => d.bytes))
  
  // Draw background
  ctx.fillStyle = '#fafafa'
  ctx.fillRect(0, 0, width, height)
  
  // Draw grid (leave space for labels)
  const chartPadding = { top: 10, bottom: 30, left: 50, right: 50 }
  const chartWidth = width - chartPadding.left - chartPadding.right
  const chartHeight = height - chartPadding.top - chartPadding.bottom
  const chartX = chartPadding.left
  const chartY = chartPadding.top
  
  ctx.strokeStyle = '#e0e0e0'
  ctx.lineWidth = 1
  for (let i = 0; i <= 5; i++) {
    const y = chartY + (chartHeight / 5) * i
    ctx.beginPath()
    ctx.moveTo(chartX, y)
    ctx.lineTo(chartX + chartWidth, y)
    ctx.stroke()
  }
  
  // Draw vertical grid lines (optional, for better readability)
  if (timeSeriesData.value.length > 1 && timeSeriesData.value.length <= 60) {
    const gridLines = Math.min(10, timeSeriesData.value.length)
    for (let i = 0; i <= gridLines; i++) {
      const x = chartX + (chartWidth / gridLines) * i
      ctx.beginPath()
      ctx.moveTo(x, chartY)
      ctx.lineTo(x, chartY + chartHeight)
      ctx.stroke()
    }
  }
  
  // Draw packets line (blue)
  if (timeSeriesData.value.length > 0) {
    ctx.strokeStyle = '#2196F3'
    ctx.lineWidth = 2
    ctx.beginPath()
    
    if (timeSeriesData.value.length === 1) {
      // Single point - draw a dot
      const x = chartX + chartWidth / 2
      const y = chartY + chartHeight - (timeSeriesData.value[0].packets / maxPackets) * chartHeight
      ctx.arc(x, y, 3, 0, Math.PI * 2)
      ctx.fillStyle = '#2196F3'
      ctx.fill()
    } else {
      // Multiple points - draw line
      const packetPoints = timeSeriesData.value.map((d, i) => {
        const x = chartX + (chartWidth / (timeSeriesData.value.length - 1)) * i
        const y = chartY + chartHeight - (d.packets / maxPackets) * chartHeight
        return { x, y }
      })
      ctx.moveTo(packetPoints[0].x, packetPoints[0].y)
      for (let i = 1; i < packetPoints.length; i++) {
        ctx.lineTo(packetPoints[i].x, packetPoints[i].y)
      }
      ctx.stroke()
    }
  }
  
  // Draw bytes line (green)
  if (timeSeriesData.value.length > 0) {
    ctx.strokeStyle = '#4CAF50'
    ctx.lineWidth = 2
    ctx.beginPath()
    
    if (timeSeriesData.value.length === 1) {
      // Single point - draw a dot
      const x = chartX + chartWidth / 2
      const y = chartY + chartHeight - (timeSeriesData.value[0].bytes / maxBytes) * chartHeight
      ctx.arc(x, y, 3, 0, Math.PI * 2)
      ctx.fillStyle = '#4CAF50'
      ctx.fill()
    } else {
      // Multiple points - draw line
      const bytesPoints = timeSeriesData.value.map((d, i) => {
        const x = chartX + (chartWidth / (timeSeriesData.value.length - 1)) * i
        const y = chartY + chartHeight - (d.bytes / maxBytes) * chartHeight
        return { x, y }
      })
      ctx.moveTo(bytesPoints[0].x, bytesPoints[0].y)
      for (let i = 1; i < bytesPoints.length; i++) {
        ctx.lineTo(bytesPoints[i].x, bytesPoints[i].y)
      }
      ctx.stroke()
    }
  }
  
  // Draw Y-axis labels (left side) - for packets
  ctx.font = '10px sans-serif'
  ctx.fillStyle = '#666'
  ctx.textAlign = 'right'
  ctx.textBaseline = 'middle'
  
  const maxPacketsLabel = Math.ceil(maxPackets)
  for (let i = 0; i <= 5; i++) {
    const value = (maxPacketsLabel / 5) * (5 - i)
    const y = chartY + (chartHeight / 5) * i
    ctx.fillText(value.toFixed(0), chartX - 10, y)
  }
  
  // Draw Y-axis labels (right side) - for bytes
  ctx.textAlign = 'left'
  const maxBytesLabel = Math.ceil(maxBytes / 1000) * 1000 // Round to nearest 1000
  for (let i = 0; i <= 5; i++) {
    const value = (maxBytesLabel / 5) * (5 - i)
    const y = chartY + (chartHeight / 5) * i
    ctx.fillText(formatBytesShort(value), chartX + chartWidth + 10, y)
  }
  
  // Draw X-axis labels (bottom)
  ctx.textAlign = 'center'
  ctx.textBaseline = 'top'
  if (timeSeriesData.value.length > 1) {
    const labelCount = Math.min(6, timeSeriesData.value.length)
    for (let i = 0; i < labelCount; i++) {
      const index = Math.floor((timeSeriesData.value.length - 1) * (i / (labelCount - 1)))
      const x = chartX + (chartWidth / (timeSeriesData.value.length - 1)) * index
      const secondsAgo = Math.floor((Date.now() - timeSeriesData.value[index].time) / 1000)
      ctx.fillText(`${secondsAgo}s`, x, chartY + chartHeight + 5)
    }
  }
  
  // Draw axis title labels
  ctx.font = '11px sans-serif'
  ctx.fillStyle = '#333'
  ctx.textAlign = 'center'
  ctx.fillText('時間 (秒前)', width / 2, height - 5)
  
  ctx.save()
  ctx.translate(15, height / 2)
  ctx.rotate(-Math.PI / 2)
  ctx.textAlign = 'center'
  ctx.fillText('封包數 / 流量', 0, 0)
  ctx.restore()
  
  // Draw legend with background for better visibility
  const legendY = 30 // Moved down more
  const legendX = 10
  const legendLineHeight = 18
  
  // Background for legend
  ctx.fillStyle = 'rgba(255, 255, 255, 0.9)'
  ctx.fillRect(legendX - 5, legendY - 12, 120, 35)
  
  // Border for legend
  ctx.strokeStyle = '#e0e0e0'
  ctx.lineWidth = 1
  ctx.strokeRect(legendX - 5, legendY - 12, 120, 35)
  
  // Legend text
  ctx.font = '12px sans-serif'
  ctx.textAlign = 'left'
  ctx.textBaseline = 'top'
  
  // Packets legend
  ctx.fillStyle = '#2196F3'
  ctx.fillRect(legendX, legendY, 12, 2)
  ctx.fillStyle = '#333'
  ctx.fillText('封包數', legendX + 18, legendY - 2)
  
  // Bytes legend
  ctx.fillStyle = '#4CAF50'
  ctx.fillRect(legendX, legendY + legendLineHeight, 12, 2)
  ctx.fillStyle = '#333'
  ctx.fillText('流量 (bytes)', legendX + 18, legendY + legendLineHeight - 2)
}

// Watch for data changes and redraw
watch([timeSeriesData, chartCanvas], () => {
  nextTick(() => {
    drawChart()
  })
}, { deep: true })

// Resize canvas
const resizeCanvas = () => {
  // Just trigger redraw, drawChart will handle sizing
  drawChart()
}

// Reset statistics
const resetStatistics = () => {
  totalPackets.value = 0
  totalBytes.value = 0
  packetsPerSecond.value = 0
  bytesPerSecond.value = 0
  timeSeriesData.value = []
  startTime.value = Date.now()
  lastTotalPackets = 0
  lastTotalBytes = 0
  lastSecondTimestamp = Date.now()
  drawChart()
}

onMounted(() => {
  resizeCanvas()
  window.addEventListener('resize', resizeCanvas)
  
  // Update chart periodically
  updateInterval = window.setInterval(() => {
    drawChart()
  }, 1000)
  
  // Calculate per-second statistics every second
  statsUpdateInterval = window.setInterval(() => {
    calculatePerSecondStats()
  }, 1000)
  
  // Initialize tracking
  lastTotalPackets = totalPackets.value
  lastTotalBytes = totalBytes.value
  lastSecondTimestamp = Date.now()
})

onUnmounted(() => {
  window.removeEventListener('resize', resizeCanvas)
  if (updateInterval !== null) {
    clearInterval(updateInterval)
  }
  if (statsUpdateInterval !== null) {
    clearInterval(statsUpdateInterval)
  }
})

// Watch connection status
watch(() => props.connected, (connected) => {
  if (connected) {
    startTime.value = Date.now()
    lastTotalPackets = totalPackets.value
    lastTotalBytes = totalBytes.value
    lastSecondTimestamp = Date.now()
  } else {
    resetStatistics()
  }
})
</script>

<style scoped>
.statistics-panel {
  display: flex;
  flex-direction: column;
  flex: 1;
  min-height: 0;
  overflow: auto;
  padding-bottom: 16px;
}

.stat-card {
  min-height: 70px;
}

.chart-container {
  position: relative;
  width: 100%;
  height: 200px;
  padding: 16px;
}

.traffic-chart {
  display: block;
  width: 100%;
  height: 200px;
  border: 1px solid #e0e0e0;
  border-radius: 4px;
  background-color: #fafafa;
}

.statistics-table {
  font-size: 12px;
}

.statistics-table :deep(.v-data-table__td) {
  font-size: 12px;
  padding: 8px 16px;
}

.statistics-table :deep(.v-data-table__th) {
  font-size: 12px;
  padding: 8px 16px;
}
</style>
