<template>
  <div class="statistics-panel">
    <div v-if="!connected" class="text-center pa-4">
      <v-icon icon="mdi-information" size="large" class="mb-2"></v-icon>
      <div>請先連線以查看統計資訊</div>
    </div>

    <div v-else>
      <!-- Statistics (Real-time + Detailed) -->
      <div class="section-card mb-4">
        <div class="section-title">
          <v-icon icon="mdi-chart-line" size="small" class="mr-2"></v-icon>
          統計資訊
        </div>
        <div class="section-content">
          <!-- Statistics Grid (Box Format) -->
          <div class="statistics-grid">
            <!-- Packet category (Blue) -->
            <div class="stat-box stat-box-packet">
              <div class="stat-label">每秒封包數 (StateUpdate)</div>
              <div class="stat-value">{{ packetsPerSecond.toFixed(1) }} 個/s</div>
            </div>
            <div class="stat-box stat-box-packet">
              <div class="stat-label">累計封包 (StateUpdate)</div>
              <div class="stat-value">{{ totalPackets }} 個</div>
            </div>
            <div class="stat-box stat-box-packet">
              <div class="stat-label">平均每秒封包數</div>
              <div class="stat-value">{{ averagePacketsPerSecond.toFixed(2) }}</div>
            </div>
            <div class="stat-box stat-box-packet">
              <div class="stat-label">最大每秒封包數</div>
              <div class="stat-value">{{ maxPacketsPerSecond }}</div>
            </div>
            
            <!-- Patch category (Orange) -->
            <div class="stat-box stat-box-patch">
              <div class="stat-label">每秒 Patch 數 (StatePatch)</div>
              <div class="stat-value">{{ patchesPerSecond.toFixed(1) }} 個/s</div>
            </div>
            <div class="stat-box stat-box-patch">
              <div class="stat-label">累計 Patch (StatePatch)</div>
              <div class="stat-value">{{ totalPatches }} 個</div>
            </div>
            <div class="stat-box stat-box-patch">
              <div class="stat-label">平均每秒 Patch 數</div>
              <div class="stat-value">{{ averagePatchesPerSecond.toFixed(2) }}</div>
            </div>
            <div class="stat-box stat-box-patch">
              <div class="stat-label">最大每秒 Patch 數</div>
              <div class="stat-value">{{ maxPatchesPerSecond }}</div>
            </div>
            
            <!-- Traffic Inbound category (Green) -->
            <div class="stat-box stat-box-traffic-inbound">
              <div class="stat-label">每秒流量 (接收)</div>
              <div class="stat-value">{{ formatBytes(bytesPerSecondInbound) }}/s</div>
            </div>
            <div class="stat-box stat-box-traffic-inbound">
              <div class="stat-label">累計流量 (接收)</div>
              <div class="stat-value">{{ formatBytes(totalBytesInbound) }}</div>
            </div>
            
            <!-- Traffic Outbound category (Teal) -->
            <div class="stat-box stat-box-traffic-outbound">
              <div class="stat-label">每秒流量 (發送)</div>
              <div class="stat-value">{{ formatBytes(bytesPerSecondOutbound) }}/s</div>
            </div>
            <div class="stat-box stat-box-traffic-outbound">
              <div class="stat-label">累計流量 (發送)</div>
              <div class="stat-value">{{ formatBytes(totalBytesOutbound) }}</div>
            </div>
            
            <!-- Traffic Total category (Deep Green) -->
            <div class="stat-box stat-box-traffic-total">
              <div class="stat-label">每秒流量 (總計)</div>
              <div class="stat-value">{{ formatBytes(bytesPerSecond) }}/s</div>
            </div>
            <div class="stat-box stat-box-traffic-total">
              <div class="stat-label">累計流量 (總計)</div>
              <div class="stat-value">{{ formatBytes(totalBytes) }}</div>
            </div>
            <div class="stat-box stat-box-traffic-total">
              <div class="stat-label">平均每秒流量 (總計)</div>
              <div class="stat-value">{{ formatBytes(averageBytesPerSecond) }}/s</div>
            </div>
            <div class="stat-box stat-box-traffic-total">
              <div class="stat-label">最大每秒流量 (總計)</div>
              <div class="stat-value">{{ formatBytes(maxBytesPerSecond) }}/s</div>
            </div>
            
            <!-- Meta category (Grey) -->
            <div class="stat-box stat-box-meta">
              <div class="stat-label">連線時間</div>
              <div class="stat-value">{{ formatUptime() }}</div>
            </div>
          </div>
        </div>
      </div>

      <!-- Traffic Chart -->
      <div class="section-card mb-4">
        <div class="section-title">
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
        </div>
        <div class="section-content">
          <div class="chart-container">
            <canvas ref="chartCanvas" class="traffic-chart"></canvas>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, computed, watch, onMounted, onUnmounted, nextTick } from 'vue'
import type { StateUpdateEntry } from '@/composables/useWebSocket'

// MessageStatistics type (matches SDK's MessageStatistics interface)
type MessageStatistics = {
  messageType: 'stateUpdate' | 'stateSnapshot' | 'transportMessage'
  messageSize: number
  direction: 'inbound' | 'outbound'
  patchCount?: number
}

const props = defineProps<{
  connected: boolean
  stateUpdates: StateUpdateEntry[]
  messageStatistics?: MessageStatistics[] // Actual message statistics from SDK
}>()

// Statistics data
const totalPackets = ref(0) // Total StateUpdate count (inbound only)
const totalPatches = ref(0) // Total StatePatch count (inbound only)
const totalBytesInbound = ref(0) // Total inbound bytes
const totalBytesOutbound = ref(0) // Total outbound bytes
const totalBytes = computed(() => totalBytesInbound.value + totalBytesOutbound.value) // Total bytes (inbound + outbound)
const packetsPerSecond = ref(0) // StateUpdates per second (inbound)
const patchesPerSecond = ref(0) // StatePatches per second (inbound)
const bytesPerSecondInbound = ref(0) // Inbound bytes per second
const bytesPerSecondOutbound = ref(0) // Outbound bytes per second
const bytesPerSecond = computed(() => bytesPerSecondInbound.value + bytesPerSecondOutbound.value) // Total bytes per second

// Time series data for chart (last 60 seconds)
const timeSeriesData = ref<Array<{ time: number; packets: number; patches: number; bytes: number }>>([])
const chartCanvas = ref<HTMLCanvasElement | null>(null)

// Track statistics
let lastProcessedUpdateIndex = 0 // Track the last processed update index
let lastProcessedStatsIndex = 0 // Track the last processed statistics index
let lastSecondTimestamp = Date.now()
let lastRecordedSecond = Math.floor(Date.now() / 1000) // Track the last second we recorded to timeSeriesData
let currentSecondPackets = 0 // StateUpdates in current second (inbound)
let currentSecondPatches = 0 // StatePatches in current second (inbound)
let currentSecondBytesInbound = 0 // Inbound bytes in current second
let currentSecondBytesOutbound = 0 // Outbound bytes in current second
let previousSecondPackets = 0 // StateUpdates in previous second (for recording)
let previousSecondPatches = 0 // StatePatches in previous second (for recording)
let previousSecondBytesInbound = 0 // Inbound bytes in previous second (for recording)
let previousSecondBytesOutbound = 0 // Outbound bytes in previous second (for recording)
let updateInterval: number | null = null
let statsUpdateInterval: number | null = null

// Update statistics from actual message statistics (from SDK)
watch(() => props.messageStatistics, (stats) => {
  // Allow empty array to pass through for initialization, but skip if null/undefined
  if (!stats) {
    return
  }
  
  // If stats array is empty, just reset the index
  if (stats.length === 0) {
    lastProcessedStatsIndex = 0
    return
  }
  
  // Calculate only NEW statistics since last check
  const newStats = stats.slice(lastProcessedStatsIndex)
  
  if (newStats.length > 0) {
    // Process each new statistic
    for (const stat of newStats) {
      if (stat.direction === 'inbound') {
        // Inbound: count StateUpdates and Patches
        if (stat.messageType === 'stateUpdate') {
          totalPackets.value += 1
          totalPatches.value += stat.patchCount || 0
        }
        totalBytesInbound.value += stat.messageSize
      } else {
        // Outbound: only count bytes
        totalBytesOutbound.value += stat.messageSize
      }
    }
    
    // Update current second statistics
    const now = Date.now()
    const currentSecond = Math.floor(now / 1000)
    const lastSecond = Math.floor(lastSecondTimestamp / 1000)
    
    // Calculate new stats for current second
    let newPackets = 0
    let newPatches = 0
    let newBytesInbound = 0
    let newBytesOutbound = 0
    
    for (const stat of newStats) {
      if (stat.direction === 'inbound') {
        if (stat.messageType === 'stateUpdate') {
          newPackets += 1
          newPatches += stat.patchCount || 0
        }
        newBytesInbound += stat.messageSize
      } else {
        newBytesOutbound += stat.messageSize
      }
    }
    
    if (currentSecond === lastSecond) {
      // Same second, accumulate
      currentSecondPackets += newPackets
      currentSecondPatches += newPatches
      currentSecondBytesInbound += newBytesInbound
      currentSecondBytesOutbound += newBytesOutbound
    } else {
      // New second detected
      // Save current second's values as previous before resetting
      previousSecondPackets = currentSecondPackets
      previousSecondPatches = currentSecondPatches
      previousSecondBytesInbound = currentSecondBytesInbound
      previousSecondBytesOutbound = currentSecondBytesOutbound
      
      // Reset and start counting for the new second
      currentSecondPackets = newPackets
      currentSecondPatches = newPatches
      currentSecondBytesInbound = newBytesInbound
      currentSecondBytesOutbound = newBytesOutbound
      lastSecondTimestamp = now
    }
    
    lastProcessedStatsIndex = stats.length
  }
  
  // Handle reset case
  if (stats.length < lastProcessedStatsIndex) {
    lastProcessedStatsIndex = 0
    // Recalculate totals from scratch
    totalPackets.value = 0
    totalPatches.value = 0
    totalBytesInbound.value = 0
    totalBytesOutbound.value = 0
    for (const stat of stats) {
      if (stat.direction === 'inbound') {
        if (stat.messageType === 'stateUpdate') {
          totalPackets.value += 1
          totalPatches.value += stat.patchCount || 0
        }
        totalBytesInbound.value += stat.messageSize
      } else {
        totalBytesOutbound.value += stat.messageSize
      }
    }
  }
}, { deep: true })

// Also track stateUpdates for patch count (fallback if messageStatistics not available)
watch(() => props.stateUpdates, (updates) => {
  if (!updates || updates.length === 0) {
    if (!props.messageStatistics || props.messageStatistics.length === 0) {
      totalPackets.value = 0
      totalPatches.value = 0
    }
    lastProcessedUpdateIndex = 0
    return
  }
  
  // Only use stateUpdates if messageStatistics is not available
  if (!props.messageStatistics || props.messageStatistics.length === 0) {
    const newUpdates = updates.slice(lastProcessedUpdateIndex)
    
    if (newUpdates.length > 0) {
      const newPatchesCount = newUpdates.reduce((sum, update) => {
        return sum + (update.patches?.length || 0)
      }, 0)
      
      totalPackets.value += newUpdates.length
      totalPatches.value += newPatchesCount
    }
    
    if (updates.length < lastProcessedUpdateIndex) {
      lastProcessedUpdateIndex = 0
      totalPackets.value = updates.length
      totalPatches.value = updates.reduce((sum, update) => {
        return sum + (update.patches?.length || 0)
      }, 0)
    } else {
      lastProcessedUpdateIndex = updates.length
    }
  }
}, { deep: true })

// Calculate per-second statistics every second
const calculatePerSecondStats = () => {
  const now = Date.now()
  const currentSecond = Math.floor(now / 1000)
  
  // If we've moved to a new second, record the previous second's data
  if (currentSecond > lastRecordedSecond) {
    // Record the data for the previous second (lastRecordedSecond)
    // Use the saved previous second values (saved by watch when new second was detected)
    const recordTimestamp = lastRecordedSecond * 1000
    
    timeSeriesData.value.push({
      time: recordTimestamp,
      packets: previousSecondPackets,
      patches: previousSecondPatches,
      bytes: previousSecondBytesInbound + previousSecondBytesOutbound
    })
    
    // Keep only last 60 seconds
    const cutoffTime = now - 60000
    timeSeriesData.value = timeSeriesData.value.filter(d => d.time >= cutoffTime)
    
    // Update display with the previous second's data (stable, updates once per second)
    // This shows "what happened in the last completed second"
    packetsPerSecond.value = previousSecondPackets
    patchesPerSecond.value = previousSecondPatches
    bytesPerSecondInbound.value = previousSecondBytesInbound
    bytesPerSecondOutbound.value = previousSecondBytesOutbound
    
    // Update lastRecordedSecond
    lastRecordedSecond = currentSecond
  } else if (timeSeriesData.value.length > 0) {
    // Same second, but we have historical data
    // Show the last recorded second's data (stable display)
    const lastData = timeSeriesData.value[timeSeriesData.value.length - 1]
    packetsPerSecond.value = lastData.packets
    patchesPerSecond.value = lastData.patches
    // Calculate bytes per second from time series (total)
    bytesPerSecondInbound.value = previousSecondBytesInbound
    bytesPerSecondOutbound.value = previousSecondBytesOutbound
  } else {
    // No historical data yet (initial state), show current second's accumulated data
    packetsPerSecond.value = currentSecondPackets
    patchesPerSecond.value = currentSecondPatches
    bytesPerSecondInbound.value = currentSecondBytesInbound
    bytesPerSecondOutbound.value = currentSecondBytesOutbound
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

const averagePatchesPerSecond = computed(() => {
  if (timeSeriesData.value.length === 0) return 0
  const total = timeSeriesData.value.reduce((sum, d) => sum + d.patches, 0)
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

const maxPatchesPerSecond = computed(() => {
  if (timeSeriesData.value.length === 0) return 0
  return Math.max(...timeSeriesData.value.map(d => d.patches))
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
  const maxPatches = Math.max(1, ...timeSeriesData.value.map(d => d.patches))
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
  
  // Draw patches line (orange)
  if (timeSeriesData.value.length > 0) {
    ctx.strokeStyle = '#FF9800'
    ctx.lineWidth = 2
    ctx.beginPath()
    
    if (timeSeriesData.value.length === 1) {
      // Single point - draw a dot
      const x = chartX + chartWidth / 2
      const y = chartY + chartHeight - (timeSeriesData.value[0].patches / maxPatches) * chartHeight
      ctx.arc(x, y, 3, 0, Math.PI * 2)
      ctx.fillStyle = '#FF9800'
      ctx.fill()
    } else {
      // Multiple points - draw line
      const patchesPoints = timeSeriesData.value.map((d, i) => {
        const x = chartX + (chartWidth / (timeSeriesData.value.length - 1)) * i
        const y = chartY + chartHeight - (d.patches / maxPatches) * chartHeight
        return { x, y }
      })
      ctx.moveTo(patchesPoints[0].x, patchesPoints[0].y)
      for (let i = 1; i < patchesPoints.length; i++) {
        ctx.lineTo(patchesPoints[i].x, patchesPoints[i].y)
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
  
  // Draw Y-axis labels (left side) - for patches
  ctx.font = '10px sans-serif'
  ctx.fillStyle = '#666'
  ctx.textAlign = 'right'
  ctx.textBaseline = 'middle'
  
  const maxPatchesLabel = Math.ceil(maxPatches)
  for (let i = 0; i <= 5; i++) {
    const value = (maxPatchesLabel / 5) * (5 - i)
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
  ctx.fillText('Patch 數 / 流量', 0, 0)
  ctx.restore()
  
  // Draw legend with background for better visibility
  const legendY = 30 // Moved down more
  const legendX = 10
  const legendLineHeight = 18
  
  // Background for legend (fits 2 items)
  ctx.fillStyle = 'rgba(255, 255, 255, 0.9)'
  ctx.fillRect(legendX - 5, legendY - 12, 140, 35)
  
  // Border for legend
  ctx.strokeStyle = '#e0e0e0'
  ctx.lineWidth = 1
  ctx.strokeRect(legendX - 5, legendY - 12, 140, 35)
  
  // Legend text
  ctx.font = '12px sans-serif'
  ctx.textAlign = 'left'
  ctx.textBaseline = 'top'
  
  // Patches legend (orange)
  ctx.fillStyle = '#FF9800'
  ctx.fillRect(legendX, legendY, 12, 2)
  ctx.fillStyle = '#333'
  ctx.fillText('Patch 數 (StatePatch)', legendX + 18, legendY - 2)
  
  // Bytes legend (green)
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
  totalPatches.value = 0
  totalBytesInbound.value = 0
  totalBytesOutbound.value = 0
  packetsPerSecond.value = 0
  patchesPerSecond.value = 0
  bytesPerSecondInbound.value = 0
  bytesPerSecondOutbound.value = 0
  timeSeriesData.value = []
  startTime.value = Date.now()
  lastProcessedUpdateIndex = 0
  lastProcessedStatsIndex = 0
  currentSecondPackets = 0
  currentSecondPatches = 0
  currentSecondBytesInbound = 0
  currentSecondBytesOutbound = 0
  previousSecondPackets = 0
  previousSecondPatches = 0
  previousSecondBytesInbound = 0
  previousSecondBytesOutbound = 0
  lastSecondTimestamp = Date.now()
  lastRecordedSecond = Math.floor(Date.now() / 1000)
  drawChart()
}

onMounted(() => {
  resizeCanvas()
  window.addEventListener('resize', resizeCanvas)
  
  // Reset all accumulated statistics when component is mounted
  // This prevents showing accumulated data from before the panel was visible
  lastProcessedUpdateIndex = 0
  // Skip all existing statistics - only process new ones from now on
  lastProcessedStatsIndex = props.messageStatistics?.length || 0
  currentSecondPackets = 0
  currentSecondPatches = 0
  currentSecondBytesInbound = 0
  currentSecondBytesOutbound = 0
  previousSecondPackets = 0
  previousSecondPatches = 0
  previousSecondBytesInbound = 0
  previousSecondBytesOutbound = 0
  lastSecondTimestamp = Date.now()
  lastRecordedSecond = Math.floor(Date.now() / 1000)
  
  // Initialize display values to zero
  packetsPerSecond.value = 0
  patchesPerSecond.value = 0
  bytesPerSecondInbound.value = 0
  bytesPerSecondOutbound.value = 0
  
  // Update chart periodically
  updateInterval = window.setInterval(() => {
    drawChart()
  }, 1000)
  
  // Calculate per-second statistics every second
  statsUpdateInterval = window.setInterval(() => {
    calculatePerSecondStats()
  }, 1000)
  
  // Initial calculation after a short delay to avoid showing accumulated data
  setTimeout(() => {
    calculatePerSecondStats()
  }, 100)
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
    // When reconnecting, skip existing statistics to avoid processing old data
    lastProcessedUpdateIndex = 0
    lastProcessedStatsIndex = props.messageStatistics?.length || 0
    currentSecondPackets = 0
    currentSecondPatches = 0
    currentSecondBytesInbound = 0
    currentSecondBytesOutbound = 0
    previousSecondPackets = 0
    previousSecondPatches = 0
    previousSecondBytesInbound = 0
    previousSecondBytesOutbound = 0
    lastSecondTimestamp = Date.now()
    lastRecordedSecond = Math.floor(Date.now() / 1000)
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
  overflow-y: auto;
  overflow-x: hidden;
  padding: 16px;
  padding-bottom: 16px;
  box-sizing: border-box;
  position: relative;
  height: 0; /* Force flex item to respect parent constraints, similar to state-tree-content */
}

.section-card {
  border: 1px solid rgba(0, 0, 0, 0.12);
  border-radius: 4px;
  background-color: rgb(var(--v-theme-surface));
  overflow: hidden;
}

.section-title {
  display: flex;
  align-items: center;
  padding: 16px;
  font-size: 0.875rem;
  font-weight: 500;
  border-bottom: 1px solid rgba(0, 0, 0, 0.12);
  height: 25px;
}

.section-content {
  padding: 16px;
}

.statistics-grid {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  gap: 12px;
}

.stat-box {
  border: 1px solid rgba(0, 0, 0, 0.12);
  border-radius: 4px;
  padding: 12px;
  background-color: rgb(var(--v-theme-surface));
  display: flex;
  flex-direction: column;
  gap: 8px;
  border-left: 4px solid transparent;
  transition: all 0.2s ease;
}

.stat-box:hover {
  box-shadow: 0 2px 4px rgba(0, 0, 0, 0.1);
}

/* Packet category - Blue */
.stat-box-packet {
  border-left-color: #2196F3;
  background-color: rgba(33, 150, 243, 0.05);
}

.stat-box-packet .stat-label {
  color: #1976D2;
}

.stat-box-packet .stat-value {
  color: #0D47A1;
}

/* Patch category - Orange */
.stat-box-patch {
  border-left-color: #FF9800;
  background-color: rgba(255, 152, 0, 0.05);
}

.stat-box-patch .stat-label {
  color: #F57C00;
}

.stat-box-patch .stat-value {
  color: #E65100;
}

/* Traffic Inbound category - Green */
.stat-box-traffic-inbound {
  border-left-color: #4CAF50;
  background-color: rgba(76, 175, 80, 0.05);
}

.stat-box-traffic-inbound .stat-label {
  color: #388E3C;
}

.stat-box-traffic-inbound .stat-value {
  color: #1B5E20;
}

/* Traffic Outbound category - Teal */
.stat-box-traffic-outbound {
  border-left-color: #009688;
  background-color: rgba(0, 150, 136, 0.05);
}

.stat-box-traffic-outbound .stat-label {
  color: #00796B;
}

.stat-box-traffic-outbound .stat-value {
  color: #004D40;
}

/* Traffic Total category - Deep Green */
.stat-box-traffic-total {
  border-left-color: #2E7D32;
  background-color: rgba(46, 125, 50, 0.05);
}

.stat-box-traffic-total .stat-label {
  color: #1B5E20;
}

.stat-box-traffic-total .stat-value {
  color: #0D2818;
}

/* Meta category - Grey */
.stat-box-meta {
  border-left-color: #757575;
  background-color: rgba(117, 117, 117, 0.05);
}

.stat-box-meta .stat-label {
  color: #616161;
}

.stat-box-meta .stat-value {
  color: #424242;
}

.stat-box .stat-label {
  font-size: 0.75rem;
  font-weight: 500;
  text-transform: uppercase;
  letter-spacing: 0.5px;
}

.stat-box .stat-value {
  font-size: 1rem;
  font-family: 'Courier New', monospace;
  font-weight: 600;
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
