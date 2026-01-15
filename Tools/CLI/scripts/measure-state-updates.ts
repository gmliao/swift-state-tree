import WebSocket from 'ws'
import { createJoinMessage, encodeMessageArrayToMessagePack } from '@swiftstatetree/sdk/core'
import { decode as msgpackDecode } from '@msgpack/msgpack'
import * as fs from 'fs'

type Counters = {
  bytes: number
  count: number
}

const args = parseArgs(process.argv.slice(2))
const url = requiredArg(args, 'url')
const land = requiredArg(args, 'land')
const durationSeconds = parseInt(args.duration ?? '60', 10)
const playerID = args.player ?? 'measure-player'
const format = args.format ?? 'opcode' // 'opcode' or 'json'
const outputPath = args.output ?? null

const { landType, landInstanceId } = parseLand(land)

const totals = {
  stateUpdate: { bytes: 0, count: 0 },
  snapshot: { bytes: 0, count: 0 },
  transport: { bytes: 0, count: 0 },
  event: { bytes: 0, count: 0 },
  other: { bytes: 0, count: 0 }
}

const ws = new WebSocket(url)
let tracking = false
let stopTimer: NodeJS.Timeout | null = null
let printedJsonFallbackNotice = false

ws.on('open', () => {
  const joinMessage = createJoinMessage(`join-${Date.now()}`, landType, landInstanceId, {
    playerID
  })

  if (format === 'messagepack') {
    const encoded = encodeMessageArrayToMessagePack(joinMessage)
    console.log(`Sending MessagePack data (${encoded.length} bytes), first 16 bytes:`, Array.from(encoded.slice(0, 16)).map(b => b.toString(16).padStart(2, '0')).join(' '))
    ws.send(encoded)
  } else {
    ws.send(JSON.stringify(joinMessage))
  }
})

ws.on('message', (data) => {
  const payload = toBuffer(data)
  const size = payload.length

  // Try to decode the message
  let decoded: any
  let decodingMethod = 'unknown'
  
  // Strategy: Try MessagePack first (if format is messagepack), then fall back to JSON
  if (format === 'messagepack') {
    // For MessagePack format, try MessagePack decode first
    try {
      decoded = msgpackDecode(payload)
      decodingMethod = 'messagepack'
    } catch (msgpackError) {
      // If MessagePack fails, try JSON as fallback.
      // This is expected for StateUpdate payloads when the server is configured with:
      // - message = messagepack
      // - stateUpdate = opcodeJsonArray (JSON text arrays)
      const firstByte = payload[0]
      const looksLikeJson = firstByte === 0x5b /* [ */ || firstByte === 0x7b /* { */
      const jsonDecoded = looksLikeJson ? safeJsonParse(payload.toString('utf8')) : null

      if (jsonDecoded !== null) {
        decoded = jsonDecoded
        decodingMethod = 'json-fallback'
        if (!printedJsonFallbackNotice) {
          printedJsonFallbackNotice = true
          console.log(
            `ℹ️  收到 JSON payload（多半是 StateUpdate 的 opcode array），在 messagepack 模式下會自動 fallback 解碼。`
          )
        }
      } else {
        if (tracking) {
          console.log(`❌ Both MessagePack and JSON decode failed. First bytes: ${payload.slice(0, 4).toString('hex')}`)
          accumulate(totals.other, size)
        }
        return
      }
    }
  } else {
    // For JSON/Opcode format, try JSON first
    const jsonDecoded = safeJsonParse(payload.toString('utf8'))
    if (jsonDecoded !== null) {
      decoded = jsonDecoded
      decodingMethod = 'json'
    } else {
      // Fallback to MessagePack (might be binary even in opcode mode)
      try {
        decoded = msgpackDecode(payload)
        decodingMethod = 'messagepack-fallback'
      } catch (msgpackError) {
        if (tracking) {
          accumulate(totals.other, size)
        }
        return
      }
    }
  }

  // Handle join response to start tracking
  let isJoinSuccess = false
  if (decoded?.kind === 'joinResponse' && decoded?.payload?.joinResponse?.success) {
    isJoinSuccess = true
  }
  // Check for Opcode Array JoinResponse: [105, requestID, success(0/1), ...]
  else if (Array.isArray(decoded) && decoded[0] === 105 && decoded[2] === 1) {
    isJoinSuccess = true
  }

  if (isJoinSuccess) {
    if (!tracking) {
      tracking = true
      console.log(`\n✅ 已加入房間，開始測量... (${durationSeconds} 秒)`)
      stopTimer = setTimeout(() => finish(), durationSeconds * 1000)
    }
  }

  if (!tracking) {
    return
  }

  // Classify message based on format
  if (format === 'opcode' || format === 'messagepack') {
    classifyOpcodeMessage(decoded, size)
  } else {
    classifyJsonMessage(decoded, size)
  }
})

function classifyOpcodeMessage(decoded: any, size: number) {
  if (!Array.isArray(decoded)) {
    accumulate(totals.other, size)
    return
  }

  const opcode = decoded[0]
  
  if (typeof opcode !== 'number') {
    accumulate(totals.other, size)
    return
  }

  // Opcode classification
  // 1 = snapshot, 2 = diff/stateUpdate, 103 = event, 100+ = transport messages
  if (opcode === 1) {
    accumulate(totals.snapshot, size)
  } else if (opcode === 2) {
    accumulate(totals.stateUpdate, size)
  } else if (opcode === 103) {
    accumulate(totals.event, size)
  } else if (opcode >= 100) {
    accumulate(totals.transport, size)
  } else {
    accumulate(totals.other, size)
  }
}

function classifyJsonMessage(decoded: any, size: number) {
  // Legacy JSON format classification
  if (Array.isArray(decoded)) {
    accumulate(totals.stateUpdate, size)
    return
  }

  if (decoded && typeof decoded === 'object') {
    if ('kind' in decoded) {
      if (decoded.kind === 'event') {
        accumulate(totals.event, size)
      } else {
        accumulate(totals.transport, size)
      }
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
}

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
    totals.stateUpdate.bytes + totals.snapshot.bytes + totals.transport.bytes + totals.event.bytes + totals.other.bytes
  const duration = durationSeconds > 0 ? durationSeconds : 1

  const report = {
    metadata: {
      format,
      duration: durationSeconds,
      landType,
      timestamp: new Date().toISOString()
    },
    totals: {
      bytes: totalBytes,
      rate: (totalBytes / duration).toFixed(2) + ' B/s'
    },
    breakdown: {
      stateUpdate: formatCounterData(totals.stateUpdate, duration),
      snapshot: formatCounterData(totals.snapshot, duration),
      event: formatCounterData(totals.event, duration),
      transport: formatCounterData(totals.transport, duration),
      other: formatCounterData(totals.other, duration)
    }
  }

  // Print to console
  console.log('\n' + '='.repeat(60))
  console.log('📊 統計資訊報告')
  console.log('='.repeat(60))
  console.log(`⏱️  測試時長: ${durationSeconds} 秒`)
  console.log(`📋 編碼格式: ${format}`)
  console.log('')
  
  // Total statistics
  console.log('📦 總計流量')
  console.log(`   總流量: ${formatBytes(totalBytes)} (${formatRate(totalBytes, duration)})`)
  console.log('')
  
  // StateUpdate statistics (main focus)
  console.log('🔄 StateUpdate (狀態更新)')
  printCounters('   ', totals.stateUpdate, duration)
  console.log('')
  
  // Event statistics
  console.log('📨 Event (事件)')
  printCounters('   ', totals.event, duration)
  console.log('')

  // Other message types
  console.log('📸 StateSnapshot (狀態快照)')
  printCounters('   ', totals.snapshot, duration)
  console.log('')
  
  console.log('🔗 Transport Messages (傳輸訊息)')
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

  // Save to file if output path is specified
  if (outputPath) {
    try {
      fs.writeFileSync(outputPath, JSON.stringify(report, null, 2))
      console.log(`\n✅ 結果已保存到: ${outputPath}`)
    } catch (error) {
      console.error(`\n❌ 保存結果失敗: ${error}`)
    }
  }
}

function formatCounterData(counters: Counters, duration: number) {
  return {
    bytes: counters.bytes,
    count: counters.count,
    avgSize: counters.count > 0 ? (counters.bytes / counters.count).toFixed(2) : '0',
    rate: (counters.bytes / duration).toFixed(2) + ' B/s',
    packetsPerSecond: (counters.count / duration).toFixed(2)
  }
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
