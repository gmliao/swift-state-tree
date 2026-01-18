import WebSocket from 'ws'
import { createJoinMessage, encodeMessageArrayToMessagePack, decodeMessage, pathHashReverseLookup, eventHashReverseLookup, clientEventHashReverseLookup } from '@swiftstatetree/sdk/core'
import type { TransportEncodingConfig } from '@swiftstatetree/sdk/types'
import * as fs from 'fs'

type Counters = {
  bytes: number
  count: number
}

interface Schema {
  version: string
  defs: Record<string, any>
  lands: Record<string, LandDefinition>
}

interface LandDefinition {
  stateType: string
  pathHashes?: Record<string, number>
  eventHashes?: Record<string, number>
  clientEventHashes?: Record<string, number>
  actions?: Record<string, { $ref: string }>
  clientEvents?: Record<string, { $ref: string }>
  events?: Record<string, { $ref: string }>
}

async function fetchSchema(baseUrl: string): Promise<Schema> {
  const schemaUrl = baseUrl.replace(/^ws:/, 'http:').replace(/^wss:/, 'https:').replace(/\/game\/.*$/, '') + '/schema'
  
  // Check if fetch is available (Node 18+)
  if (typeof fetch === 'undefined') {
    throw new Error('fetch is not available. This script requires Node.js 18+ or a fetch polyfill.')
  }
  
  try {
    const response = await fetch(schemaUrl)
    if (!response.ok) {
      throw new Error(`Failed to fetch schema: ${response.status} ${response.statusText}`)
    }
    const schema = await response.json() as Schema
    return schema
  } catch (error) {
    throw new Error(`Failed to fetch schema from ${schemaUrl}: ${error}`)
  }
}

function initializeSchemaLookups(schema: Schema, landType: string): void {
  const landDef = schema.lands[landType]
  if (!landDef) {
    console.warn(`⚠️  Land definition not found for '${landType}' in schema. Available lands: ${Object.keys(schema.lands).join(', ')}`)
    return
  }

  // Initialize path hash reverse lookup table
  if (landDef.pathHashes) {
    pathHashReverseLookup.clear()
    for (const [pattern, hash] of Object.entries(landDef.pathHashes)) {
      pathHashReverseLookup.set(hash, pattern)
    }
    console.log(`✅ Loaded ${pathHashReverseLookup.size} path hashes for '${landType}'`)
  }

  // Initialize event hash reverse lookup tables
  if (landDef.eventHashes) {
    eventHashReverseLookup.clear()
    for (const [type, hash] of Object.entries(landDef.eventHashes)) {
      eventHashReverseLookup.set(hash, type)
    }
    console.log(`✅ Loaded ${eventHashReverseLookup.size} event hashes for '${landType}'`)
  }

  if (landDef.clientEventHashes) {
    clientEventHashReverseLookup.clear()
    for (const [type, hash] of Object.entries(landDef.clientEventHashes)) {
      clientEventHashReverseLookup.set(hash, type)
    }
    console.log(`✅ Loaded ${clientEventHashReverseLookup.size} client event hashes for '${landType}'`)
  }
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

let ws: WebSocket | null = null
let tracking = false
let stopTimer: NodeJS.Timeout | null = null

async function startMeasurement() {
  // Load schema before connecting (required for opcode/messagepack formats)
  if (format === 'opcode' || format === 'messagepack') {
    try {
      console.log('📥 Loading schema from server...')
      const schema = await fetchSchema(url)
      initializeSchemaLookups(schema, landType)
    } catch (error) {
      console.error(`❌ Failed to load schema: ${error}`)
      console.error('⚠️  Continuing without schema - opcode decoding may fail')
    }
  }

  // Connect WebSocket after schema is loaded
  ws = new WebSocket(url)
  
  ws.on('open', () => {
    if (!ws) return
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

    // Use unified decodeMessage function from SDK
    // Configure encoding based on format parameter
    const encodingConfig: TransportEncodingConfig = {
      message: format === 'messagepack' ? 'messagepack' : format === 'opcode' ? 'opcodeJsonArray' : 'json',
      stateUpdate: format === 'json' ? 'jsonObject' : 'opcodeJsonArray',
      stateUpdateDecoding: 'auto'
    }

    let decoded: any
    try {
      decoded = decodeMessage(payload, encodingConfig)
    } catch (error) {
      if (tracking) {
        console.log(`❌ Failed to decode message: ${error}. First bytes: ${payload.slice(0, 4).toString('hex')}`)
        accumulate(totals.other, size)
      }
      return
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

    // Classify message based on decoded structure
    // decodeMessage converts opcode arrays to structured objects, so we check the object structure
    classifyDecodedMessage(decoded, size)
  })

function classifyDecodedMessage(decoded: any, size: number) {
  // Check if it's a StateUpdate (diff or snapshot)
  if (decoded && typeof decoded === 'object') {
    if ('type' in decoded) {
      // StateUpdate format: { type: 'diff' | 'firstSync', patches: [...] }
      if (decoded.type === 'firstSync' || decoded.type === 'snapshot') {
        accumulate(totals.snapshot, size)
        return
      } else if (decoded.type === 'diff') {
        accumulate(totals.stateUpdate, size)
        return
      }
    }
    
    // Check if it's a TransportMessage
    if ('kind' in decoded) {
      if (decoded.kind === 'event') {
        accumulate(totals.event, size)
        return
      } else {
        // Other transport messages (joinResponse, actionResponse, error, etc.)
        accumulate(totals.transport, size)
        return
      }
    }
    
    // Check for legacy snapshot format: { values: {...} }
    if ('values' in decoded) {
      accumulate(totals.snapshot, size)
      return
    }
  }
  
  // Check if it's still an opcode array (shouldn't happen after decodeMessage, but handle it)
  if (Array.isArray(decoded) && decoded.length > 0) {
    const opcode = decoded[0]
    if (typeof opcode === 'number') {
      // Opcode classification
      // 1 = snapshot, 2 = diff/stateUpdate, 103 = event, 100+ = transport messages
      if (opcode === 1) {
        accumulate(totals.snapshot, size)
        return
      } else if (opcode === 2) {
        accumulate(totals.stateUpdate, size)
        return
      } else if (opcode === 103) {
        accumulate(totals.event, size)
        return
      } else if (opcode >= 100) {
        accumulate(totals.transport, size)
        return
      }
    }
  }

  // Unknown format
  accumulate(totals.other, size)
}


  ws.on('error', (error) => {
    console.error(`WebSocket error: ${error}`)
    finish()
  })

  ws.on('close', () => {
    finish()
  })
}

// Start the measurement process
startMeasurement().catch((error) => {
  console.error(`Failed to start measurement: ${error}`)
  process.exit(1)
})

function finish() {
  if (stopTimer) {
    clearTimeout(stopTimer)
    stopTimer = null
  }
  if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) {
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
