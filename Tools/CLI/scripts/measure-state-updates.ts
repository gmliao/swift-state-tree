import WebSocket from 'ws'
import { createJoinMessage } from '@swiftstatetree/sdk/core'

type Counters = {
  bytes: number
  count: number
}

const args = parseArgs(process.argv.slice(2))
const url = requiredArg(args, 'url')
const land = requiredArg(args, 'land')
const durationSeconds = parseInt(args.duration ?? '60', 10)
const playerID = args.player ?? 'measure-player'

const { landType, landInstanceId } = parseLand(land)

const totals = {
  stateUpdate: { bytes: 0, count: 0 },
  snapshot: { bytes: 0, count: 0 },
  transport: { bytes: 0, count: 0 },
  other: { bytes: 0, count: 0 }
}

const ws = new WebSocket(url)
let tracking = false
let stopTimer: NodeJS.Timeout | null = null

ws.on('open', () => {
  const joinMessage = createJoinMessage(`join-${Date.now()}`, landType, landInstanceId, {
    playerID
  })
  ws.send(JSON.stringify(joinMessage))
})

ws.on('message', (data) => {
  const payload = toBuffer(data)
  const size = payload.length
  const decoded = safeJsonParse(payload.toString('utf8'))

  if (decoded?.kind === 'joinResponse' && decoded?.payload?.joinResponse?.success) {
    if (!tracking) {
      tracking = true
      stopTimer = setTimeout(() => finish(), durationSeconds * 1000)
    }
  }

  if (!tracking) {
    return
  }

  if (Array.isArray(decoded)) {
    accumulate(totals.stateUpdate, size)
    return
  }

  if (decoded && typeof decoded === 'object') {
    if ('kind' in decoded) {
      accumulate(totals.transport, size)
      return
    }
    if ('type' in decoded && 'patches' in decoded) {
      accumulate(totals.stateUpdate, size)
      return
    }
    if ('values' in decoded) {
      accumulate(totals.snapshot, size)
      return
    }
  }

  accumulate(totals.other, size)
})

ws.on('error', (error) => {
  console.error(`WebSocket error: ${error}`)
  finish()
})

ws.on('close', () => {
  finish()
})

function finish() {
  if (stopTimer) {
    clearTimeout(stopTimer)
    stopTimer = null
  }
  if (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING) {
    ws.close()
  }
  printReport()
  process.exit(0)
}

function printReport() {
  const totalBytes =
    totals.stateUpdate.bytes + totals.snapshot.bytes + totals.transport.bytes + totals.other.bytes
  const duration = durationSeconds > 0 ? durationSeconds : 1

  console.log('\n' + '='.repeat(60))
  console.log('📊 統計資訊報告')
  console.log('='.repeat(60))
  console.log(`⏱️  測試時長: ${durationSeconds} 秒`)
  console.log('')
  
  // Total statistics
  console.log('📦 總計流量')
  console.log(`   總流量: ${formatBytes(totalBytes)} (${formatRate(totalBytes, duration)})`)
  console.log('')
  
  // StateUpdate statistics (main focus)
  console.log('🔄 StateUpdate (狀態更新)')
  printCounters('   ', totals.stateUpdate, duration)
  console.log('')
  
  // Other message types
  console.log('📸 StateSnapshot (狀態快照)')
  printCounters('   ', totals.snapshot, duration)
  console.log('')
  
  console.log('📨 Transport Messages (傳輸訊息)')
  printCounters('   ', totals.transport, duration)
  console.log('')
  
  if (totals.other.count > 0) {
    console.log('❓ Other (其他)')
    printCounters('   ', totals.other, duration)
    console.log('')
  }
  
  // Summary comparison (if we have StateUpdate data)
  if (totals.stateUpdate.count > 0) {
    const avgSize = totals.stateUpdate.bytes / totals.stateUpdate.count
    const packetsPerSecond = totals.stateUpdate.count / duration
    console.log('📈 StateUpdate 摘要')
    console.log(`   平均封包大小: ${avgSize.toFixed(2)} bytes`)
    console.log(`   每秒封包數: ${packetsPerSecond.toFixed(2)} 個/s`)
    console.log(`   累計封包數: ${totals.stateUpdate.count} 個`)
    console.log('')
  }
  
  console.log('='.repeat(60))
}

function printCounters(prefix: string, counters: Counters, duration: number) {
  const avg = counters.count > 0 ? (counters.bytes / counters.count).toFixed(2) : '0'
  const perSecond = counters.count / duration
  console.log(
    `${prefix}累計流量: ${formatBytes(counters.bytes)} (${formatRate(counters.bytes, duration)})`
  )
  console.log(
    `${prefix}累計封包: ${counters.count} 個 (${perSecond.toFixed(2)} 個/s)`
  )
  console.log(
    `${prefix}平均大小: ${avg} bytes/封包`
  )
}

function formatBytes(bytes: number): string {
  if (bytes === 0) return '0 B'
  const k = 1024
  const sizes = ['B', 'KB', 'MB', 'GB']
  const i = Math.floor(Math.log(bytes) / Math.log(k))
  return `${(bytes / Math.pow(k, i)).toFixed(2)} ${sizes[i]}`
}

function formatRate(bytes: number, duration: number) {
  const perSecond = bytes / duration
  return `${perSecond.toFixed(2)} B/s`
}

function accumulate(counter: Counters, size: number) {
  counter.bytes += size
  counter.count += 1
}

function toBuffer(data: WebSocket.RawData): Buffer {
  if (Buffer.isBuffer(data)) {
    return data
  }
  if (data instanceof ArrayBuffer) {
    return Buffer.from(data)
  }
  if (ArrayBuffer.isView(data)) {
    return Buffer.from(data.buffer)
  }
  return Buffer.from(String(data))
}

function safeJsonParse(text: string): any {
  try {
    return JSON.parse(text)
  } catch {
    return null
  }
}

function parseLand(land: string) {
  const [landType, landInstanceId] = land.split(':', 2)
  return {
    landType,
    landInstanceId: landInstanceId ?? null
  }
}

function parseArgs(values: string[]) {
  const result: Record<string, string> = {}
  for (let i = 0; i < values.length; i += 1) {
    const value = values[i]
    if (!value.startsWith('--')) {
      continue
    }
    const key = value.slice(2)
    const next = values[i + 1]
    if (!next || next.startsWith('--')) {
      result[key] = 'true'
    } else {
      result[key] = next
      i += 1
    }
  }
  return result
}

function requiredArg(args: Record<string, string>, key: string) {
  const value = args[key]
  if (!value) {
    console.error(`Missing required --${key}`)
    process.exit(1)
  }
  return value
}
