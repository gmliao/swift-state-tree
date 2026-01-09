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

  console.log(`Duration: ${durationSeconds}s`)
  console.log(`Total bytes: ${totalBytes} (${formatRate(totalBytes, duration)})`)
  printCounters('StateUpdate', totals.stateUpdate, duration)
  printCounters('Snapshot', totals.snapshot, duration)
  printCounters('Transport', totals.transport, duration)
  printCounters('Other', totals.other, duration)
}

function printCounters(label: string, counters: Counters, duration: number) {
  const avg = counters.count > 0 ? (counters.bytes / counters.count).toFixed(2) : '0'
  console.log(
    `${label}: ${counters.bytes} bytes, ${counters.count} msgs, avg ${avg} bytes (${formatRate(counters.bytes, duration)})`
  )
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
