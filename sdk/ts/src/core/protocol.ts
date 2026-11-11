import type {
  TransportMessage,
  TransportActionPayload,
  TransportJoinPayload,
  TransportEventPayload,
  StatePatch,
  StateUpdate,
  StateSnapshot,
  StateUpdateWithEvents,
  TransportEncodingConfig,
  StateUpdateDecoding,
  MessageEncoding
} from '../types/transport'
import { 
  MessageEncodingValues, 
  StateUpdateEncodingValues, 
  StateUpdateDecodingValues 
} from '../types/transport'
import { encode as msgpackEncode, decode as msgpackDecode } from '@msgpack/msgpack'
import { NoOpLogger, type Logger } from './logger'

/**
 * Debug output of the decode functions (one line per compressed event payload, for example).
 * Off by default: every decoded frame would otherwise pay for a console write. Pass a logger
 * (such as `ConsoleLogger`) to see it; it applies to every decode in the process.
 */
let protocolLogger: Logger = new NoOpLogger()

export function setProtocolLogger(logger: Logger | undefined): void {
  protocolLogger = logger ?? new NoOpLogger()
}

/**
 * Opcode constants for TransportMessage types
 * Uses 101+ range to avoid conflict with StateUpdateOpcode (0-2)
 * Matches Swift MessageKindOpcode enum
 */
export const MessageKindOpcode = {
  action: 101,
  actionResponse: 102,
  event: 103,
  join: 104,
  joinResponse: 105,
  error: 106,
  /** State update with events merged (107). Same wire range as MessageKindOpcode. */
  stateUpdateWithEvents: 107
} as const

/**
 * Opcode constants for StateUpdate types
 * Matches Swift StateUpdateOpcode enum
 */
export const StateUpdateOpcode = {
  noChange: 0,
  firstSync: 1,
  diff: 2,
  /** A fresh full view for a client that fell behind (#332); only with `syncSequence`. */
  resync: 3
} as const

/**
 * Opcode constants for StatePatch operations
 * Matches Swift StatePatchOpcode enum
 */
export const StatePatchOpcode = {
  replace: 1,  // set
  remove: 2,
  add: 3
} as const

/**
 * Ops of a merged entry, `[parentId, dynamicKey, op, fieldMask, v1, v2, …]` (Swift
 * `MergedPatchOpcode`): one patch per mask bit, in ascending bit order.
 */
export const MergedPatchOpcode = {
  set: 4,
  add: 5
} as const

/**
 * Event direction constants
 */
export const EventDirection = {
  fromClient: 0,
  fromServer: 1
} as const

/**
 * Encode a TransportMessage to JSON string
 */
export function encodeMessage(message: TransportMessage): string {
  return JSON.stringify(message)
}

/**
 * Build the opcode array structure for a TransportMessage
 * This is the common logic used by both JSON and MessagePack encoding
 * 
 * Formats:
 * - joinResponse: [MessageKindOpcode.joinResponse, requestID, success(0/1), landType?, landInstanceId?, playerSlot?, encoding?, reason?, stateUpdateFeatures?]
 * - actionResponse: [MessageKindOpcode.actionResponse, requestID, response]
 * - error: [MessageKindOpcode.error, code, message, details?]
 * - action: [MessageKindOpcode.action, requestID, typeIdentifier, payload(object)]
 * - join: [MessageKindOpcode.join, requestID, landType, landInstanceId?, playerID?, deviceID?, metadata?]
 * - event: [MessageKindOpcode.event, direction(EventDirection.fromClient/fromServer), type, payload, rawBody?]
 */
function buildMessageArray(message: TransportMessage): any[] {
  const array: any[] = []
  
  switch (message.kind) {
    case 'joinResponse': {
      const payload = (message.payload as any).joinResponse
      if (!payload) throw new Error('Invalid joinResponse payload')
      
      array.push(MessageKindOpcode.joinResponse)
      array.push(payload.requestID)
      array.push(payload.success ? 1 : 0)
      
      // Optional fields - include encoding if present
      // Optional fields, positional, up to the last one present.
      const optionals = [
        payload.landType, payload.landInstanceId, payload.playerSlot,
        payload.encoding, payload.reason, payload.stateUpdateFeatures
      ]
      let last = optionals.length - 1
      while (last >= 0 && optionals[last] == null) last--
      for (let i = 0; i <= last; i++) array.push(optionals[i] ?? null)
      break
    }
    
    case 'actionResponse': {
      const payload = (message.payload as any).actionResponse
      if (!payload) throw new Error('Invalid actionResponse payload')
      
      array.push(MessageKindOpcode.actionResponse)
      array.push(payload.requestID)
      array.push(payload.response)
      break
    }
    
    case 'error': {
      const payload = message.payload as any
      if (!payload.error) throw new Error('Invalid error payload')
      
      array.push(MessageKindOpcode.error)
      array.push(payload.error.code)
      array.push(payload.error.message)
      if (payload.error.details != null) {
        array.push(payload.error.details)
      }
      break
    }
    
    case 'action': {
      const payload = message.payload as any
      if (!payload.requestID || !payload.typeIdentifier || !payload.payload) {
        throw new Error('Invalid action payload')
      }
      
      array.push(MessageKindOpcode.action)
      array.push(payload.requestID)
      array.push(payload.typeIdentifier)
      array.push(payload.payload || {}) // JSON object (same as Event payload)
      break
    }
    
    case 'join': {
      const payload = (message.payload as any).join
      if (!payload) throw new Error('Invalid join payload')
      
      array.push(MessageKindOpcode.join)
      array.push(payload.requestID)
      array.push(payload.landType)
      
      // Optional trailing fields
      if (payload.landInstanceId != null || payload.playerID != null || payload.deviceID != null || payload.metadata != null) {
        array.push(payload.landInstanceId ?? null)
      }
      if (payload.playerID != null || payload.deviceID != null || payload.metadata != null) {
        array.push(payload.playerID ?? null)
      }
      if (payload.deviceID != null || payload.metadata != null) {
        array.push(payload.deviceID ?? null)
      }
      if (payload.metadata != null) {
        array.push(payload.metadata)
      }
      break
    }
    
    case 'event': {
      const payload = message.payload as any
      const fromClient = payload.fromClient
      const fromServer = payload.fromServer
      
      array.push(MessageKindOpcode.event)
      
      if (fromClient) {
        array.push(EventDirection.fromClient)
        array.push(fromClient.type)
        array.push(fromClient.payload || {})
        if (fromClient.rawBody != null) {
          array.push(fromClient.rawBody)
        }
      } else if (fromServer) {
        array.push(EventDirection.fromServer)
        array.push(fromServer.type)
        array.push(fromServer.payload || {})
        if (fromServer.rawBody != null) {
          array.push(fromServer.rawBody)
        }
      } else {
        throw new Error('Invalid event payload: missing fromClient or fromServer')
      }
      break
    }
    
    default:
      throw new Error(`Unsupported message kind: ${message.kind}`)
  }
  
  return array
}

/**
 * Encode a TransportMessage to opcode JSON array format
 * 
 * Formats:
 * - joinResponse: [MessageKindOpcode.joinResponse, requestID, success(0/1), landType?, landInstanceId?, playerSlot?, encoding?, reason?, stateUpdateFeatures?]
 * - actionResponse: [MessageKindOpcode.actionResponse, requestID, response]
 * - error: [MessageKindOpcode.error, code, message, details?]
 * - action: [MessageKindOpcode.action, requestID, typeIdentifier, payload(object)]
 * - join: [MessageKindOpcode.join, requestID, landType, landInstanceId?, playerID?, deviceID?, metadata?]
 * - event: [MessageKindOpcode.event, direction(EventDirection.fromClient/fromServer), type, payload, rawBody?]
 */
export function encodeMessageArray(message: TransportMessage): string {
  const array = buildMessageArray(message)
  return JSON.stringify(array)
}

/**
 * Encode a TransportMessage to MessagePack binary format
 * Uses the same array structure as encodeMessageArray but serializes with MessagePack
 * 
 * @param message - The TransportMessage to encode
 * @returns Uint8Array containing MessagePack-encoded array
 */
export function encodeMessageArrayToMessagePack(message: TransportMessage): Uint8Array {
  const array = buildMessageArray(message)
  return msgpackEncode(array)
}

/** The sync ack's opcode: `[108, seq]`, after the message kinds (101-106) and 107. */
export const SYNC_ACK_OPCODE = 108

/**
 * A sync ack: the latest sync sequence this client has applied, `[108, seq]`, as JSON text for
 * `json` and `opcodeJsonArray` and as MessagePack for `messagepack`. Not a TransportMessage: the
 * server reads it before message decoding and never hands it to the land.
 */
export function encodeSyncAck(seq: number, format: MessageEncoding): string | Uint8Array {
  if (!Number.isSafeInteger(seq) || seq < 0) {
    throw new Error(`Invalid sync sequence: ${seq}`)
  }
  const array = [SYNC_ACK_OPCODE, seq]
  return format === 'messagepack' ? msgpackEncode(array) : JSON.stringify(array)
}

/**
 * Encode a TransportMessage to the specified format
 * Unified encoding function that handles all three encoding formats
 * 
 * @param message - The TransportMessage to encode
 * @param format - The encoding format to use
 * @returns Encoded message as string (for json/opcodeJsonArray) or Uint8Array (for messagepack)
 */
export function encodeMessageToFormat(
  message: TransportMessage,
  format: MessageEncoding
): string | Uint8Array {
  switch (format) {
    case MessageEncodingValues.json:
      return encodeMessage(message)
    case MessageEncodingValues.opcodeJsonArray:
      return encodeMessageArray(message)
    case MessageEncodingValues.messagepack:
      return encodeMessageArrayToMessagePack(message)
    default:
      // Fallback to JSON for unknown formats
      return encodeMessage(message)
  }
}

/**
 * Try to decode binary data as MessagePack
 * @returns Decoded array or null if decode fails
 */
function tryDecodeAsMessagePack(data: ArrayBuffer | Uint8Array): any[] | null {
  try {
    const uint8Array = data instanceof ArrayBuffer ? new Uint8Array(data) : data
    return msgpackDecode(uint8Array) as any[]
  } catch {
    return null
  }
}

/**
 * Try to decode data as JSON (string or binary)
 * @returns Decoded object or null if decode fails
 */
function tryDecodeAsJson(data: string | ArrayBuffer | Uint8Array): any | null {
  try {
    if (typeof data === 'string') {
      return JSON.parse(data)
    } else {
      // Binary data - try to decode as UTF-8 text
      const text = new TextDecoder().decode(
        data instanceof ArrayBuffer ? new Uint8Array(data) : data
      )
      return JSON.parse(text)
    }
  } catch {
    return null
  }
}

type DynamicKeyMaps = {
  broadcast?: Map<number, string>
  perPlayer?: Map<number, string>
  /** The connection's row tables, needed to decode row entries (`rowAddressing`). */
  rowTables?: RowTables
}

type DynamicKeyMapInput = Map<number, string> | DynamicKeyMaps

/** Row patch opcodes (`rowAddressing`), read before entry[1]: a row entry's entry[1] is a slot or a slot list. */
export const RowPatchOpcode = {
  /** `[tableId, slot, 6, generation, parentSlot (null), key, value]`: a new row, whole. */
  create: 6,
  /** `[tableId, slot, 7]`: the row and everything below it is removed. */
  delete: 7,
  /** `[leafPathId, [slot, …], 8, [value, …]]`: one leaf set in those rows, slots ascending. */
  columnSet: 8,
  /** `[leafPathId, [slot, …], 9]`: one leaf removed in those rows, slots ascending. */
  columnClear: 9
} as const

/**
 * A row entry that breaks the strict rules (a slot unbound or already bound, a generation not
 * above the slot's last, a malformed entry, or a row entry without `rowAddressing` negotiated).
 * The connection's state can no longer be trusted: the runtime closes it rather than drop the
 * frame. `rule` names the rule broken.
 */
export class RowEntryProtocolError extends Error {
  constructor(readonly rule: string) {
    super(rule)
    this.name = 'RowEntryProtocolError'
  }
}

/**
 * A connection's row tables: per table (the hash of its `<pattern>.*`), the key bound to each
 * slot, and each slot's last generation, which survives the slot's delete. Slots are broadcast
 * only, so there is one set per connection, not one per key scope. Cleared on a resync, not on a
 * key-scope-reset firstSync (the Swift decoder does the same).
 */
export class RowTables {
  private readonly keys = new Map<number, Map<number, string>>()
  private readonly generations = new Map<number, Map<number, number>>()

  key(table: number, slot: number): string | undefined {
    return this.keys.get(table)?.get(slot)
  }

  lastGeneration(table: number, slot: number): number | undefined {
    return this.generations.get(table)?.get(slot)
  }

  bind(table: number, slot: number, key: string, generation: number): void {
    let keys = this.keys.get(table)
    if (!keys) this.keys.set(table, (keys = new Map()))
    keys.set(slot, key)
    let generations = this.generations.get(table)
    if (!generations) this.generations.set(table, (generations = new Map()))
    generations.set(slot, generation)
  }

  unbind(table: number, slot: number): void {
    this.keys.get(table)?.delete(slot)
  }

  clear(): void {
    this.keys.clear()
    this.generations.clear()
  }

  /** The bound slots of `table`, with their keys and generations. */
  bound(table: number): Map<number, { key: string; generation: number }> {
    const result = new Map<number, { key: string; generation: number }>()
    for (const [slot, key] of this.keys.get(table) ?? []) {
      result.set(slot, { key, generation: this.generations.get(table)?.get(slot) ?? 0 })
    }
    return result
  }

  /** The tables with at least one bound slot. */
  boundTables(): number[] {
    return [...this.keys].filter(([, slots]) => slots.size > 0).map(([table]) => table)
  }
}

/**
 * The indices, in a decoded update's `patches`, of the patches that came from row entries. Kept
 * off the exported `StatePatch`: the runtime reads it (the resync skip), views never see it.
 */
const ROW_PATCH_INDICES = Symbol('rowPatchIndices')

/** The row-derived patch indices of `update`, empty when it has none. */
export function rowPatchIndicesOf(update: StateUpdate): readonly number[] {
  return (update as { [ROW_PATCH_INDICES]?: number[] })[ROW_PATCH_INDICES] ?? []
}

function resolveDynamicKeyMap(
  input: DynamicKeyMapInput | undefined,
  scope: 'broadcast' | 'perPlayer'
): Map<number, string> | undefined {
  if (!input) return undefined
  if (input instanceof Map) return input
  return scope === 'broadcast' ? input.broadcast : input.perPlayer
}

/**
 * Classify decoded data and route to appropriate decoder
 */
function classifyAndDecode(
  decoded: any,
  config: TransportEncodingConfig | undefined,
  dynamicKeyMap: DynamicKeyMapInput | undefined
): TransportMessage | StateUpdate | StateSnapshot | StateUpdateWithEvents {
  if (Array.isArray(decoded)) {
    const firstElement = decoded[0]
    // Opcode 107: state update with events merged
    if (typeof firstElement === 'number' && firstElement === MessageKindOpcode.stateUpdateWithEvents) {
      const broadcastMap = resolveDynamicKeyMap(dynamicKeyMap, 'broadcast')
      return decodeStateUpdateWithEventsArray(decoded, broadcastMap, pathIndexTableOf(config), config?.pathPatterns, syncSequenceOf(config), rowsOf(config, dynamicKeyMap))
    }
    // Check if first element is a TransportMessage opcode (101-106)
    if (typeof firstElement === 'number' && 
        firstElement >= MessageKindOpcode.action && 
        firstElement <= MessageKindOpcode.error) {
      return decodeTransportMessageArray(decoded)
    }
    
    // Otherwise, treat as StateUpdate opcode array (0-2)
    const decoding = resolveStateUpdateDecoding(config)
    if (decoding === StateUpdateDecodingValues.jsonObject) {
      throw new Error(`Unknown message format: ${JSON.stringify(decoded).substring(0, 100)}`)
    }
    const perPlayerMap = resolveDynamicKeyMap(dynamicKeyMap, 'perPlayer')
    return decodeStateUpdateArray(decoded, perPlayerMap, pathIndexTableOf(config), config?.pathPatterns, syncSequenceOf(config), rowsOf(config, dynamicKeyMap))
  }

  // Check for TransportMessage with kind field
  if (decoded && typeof decoded === 'object' && 'kind' in decoded) {
    return decoded as TransportMessage
  }

  // Check for StateUpdate
  if (decoded && typeof decoded === 'object' && 'type' in decoded && 'patches' in decoded) {
    const decoding = resolveStateUpdateDecoding(config)
    if (decoding === StateUpdateDecodingValues.opcodeJsonArray) {
      throw new Error(`Unknown message format: ${JSON.stringify(decoded).substring(0, 100)}`)
    }
    return decoded as StateUpdate
  }

  // Check for StateSnapshot
  if (decoded && typeof decoded === 'object' && 'values' in decoded) {
    return decoded as StateSnapshot
  }

  throw new Error(`Unknown message format: ${JSON.stringify(decoded).substring(0, 100)}`)
}

/**
 * Decode a JSON string or MessagePack binary data to TransportMessage, StateUpdate, or StateSnapshot
 * Optimized to use known encoding format when available (after joinResponse)
 */
export function decodeMessage(
  data: string | ArrayBuffer | Uint8Array,
  config?: TransportEncodingConfig,
  dynamicKeyMap?: DynamicKeyMapInput
): TransportMessage | StateUpdate | StateSnapshot | StateUpdateWithEvents {
  const knownEncoding = config?.message
  
  // Handle binary data (ArrayBuffer or Uint8Array)
  if (data instanceof ArrayBuffer || data instanceof Uint8Array) {
    // If we know the encoding is messagepack, try MessagePack first
    if (knownEncoding === MessageEncodingValues.messagepack) {
      const msgpackDecoded = tryDecodeAsMessagePack(data)
      if (msgpackDecoded !== null) {
        return classifyAndDecode(msgpackDecoded, config, dynamicKeyMap)
      }
      // If MessagePack fails, fallback to JSON (server may send JSON text as binary)
      const jsonDecoded = tryDecodeAsJson(data)
      if (jsonDecoded !== null) {
        return classifyAndDecode(jsonDecoded, config, dynamicKeyMap)
      }
      throw new Error(`Failed to decode binary data as MessagePack or JSON`)
    }
    
    // If we know the encoding is opcodeJsonArray or json, try JSON first
    if (knownEncoding === MessageEncodingValues.opcodeJsonArray || knownEncoding === MessageEncodingValues.json) {
      const jsonDecoded = tryDecodeAsJson(data)
      if (jsonDecoded !== null) {
        return classifyAndDecode(jsonDecoded, config, dynamicKeyMap)
      }
      // Fallback to MessagePack (might be binary even in opcode mode)
      const msgpackDecoded = tryDecodeAsMessagePack(data)
      if (msgpackDecoded !== null) {
        return classifyAndDecode(msgpackDecoded, config, dynamicKeyMap)
      }
      throw new Error(`Failed to decode binary data as JSON or MessagePack`)
    }
    
    // Unknown encoding (before joinResponse) - try both formats
    const msgpackDecoded = tryDecodeAsMessagePack(data)
    if (msgpackDecoded !== null) {
      return classifyAndDecode(msgpackDecoded, config, dynamicKeyMap)
    }
    
    const jsonDecoded = tryDecodeAsJson(data)
    if (jsonDecoded !== null) {
      return classifyAndDecode(jsonDecoded, config, dynamicKeyMap)
    }
    
    throw new Error(`Failed to decode binary data: tried MessagePack and JSON, both failed`)
  }
  
  // Handle JSON string
  const jsonDecoded = tryDecodeAsJson(data as string)
  if (jsonDecoded === null) {
    throw new Error(`Failed to parse JSON string`)
  }
  
  return classifyAndDecode(jsonDecoded, config, dynamicKeyMap)
}

function resolveStateUpdateDecoding(config?: TransportEncodingConfig): StateUpdateDecoding {
  return config?.stateUpdateDecoding ?? StateUpdateDecodingValues.auto
}

/**
 * The rank table when the server's frames carry path indices (`joinResponse.stateUpdateFeatures`);
 * undefined when path ids are hashes.
 */
function pathIndexTableOf(config?: TransportEncodingConfig): readonly number[] | undefined {
  if (!(config?.stateUpdateFeatures?.includes(StateUpdateFeatures.pathIndex) ?? false)) return undefined
  if (!config?.pathIndexTable) {
    throw new Error('Path index in use but no path index table: the joined land has no pathHashes in the schema')
  }
  return config.pathIndexTable
}

/** Whether the server's frames carry the sync sequence (`joinResponse.stateUpdateFeatures`). */
function syncSequenceOf(config?: TransportEncodingConfig): boolean {
  return config?.stateUpdateFeatures?.includes(StateUpdateFeatures.syncSequence) ?? false
}

/**
 * How row entries are read: `negotiated` when the join response named `rowAddressing`, and the
 * connection's row tables when the caller passed them.
 */
type RowDecoding = { negotiated: boolean; tables?: RowTables }

function rowsOf(config: TransportEncodingConfig | undefined, input: DynamicKeyMapInput | undefined): RowDecoding {
  return {
    negotiated: config?.stateUpdateFeatures?.includes(StateUpdateFeatures.rowAddressing) ?? false,
    tables: input instanceof Map ? undefined : input?.rowTables,
  }
}

/** `value` as an integer in `0...limit`, exactly; undefined for anything else (a boolean, a fraction, a negative, out of range). */
function exactCount(value: unknown, limit: number): number | undefined {
  if (typeof value === 'number') {
    return Number.isSafeInteger(value) && value >= 0 && value <= limit ? value : undefined
  }
  if (typeof value === 'bigint') {
    return value >= 0n && value <= BigInt(limit) ? Number(value) : undefined
  }
  return undefined
}

const INT32_MAX = 2147483647
const UINT32_MAX = 4294967295

function decodeStateUpdateArray(
  payload: unknown[],
  dynamicKeyMap?: Map<number, string>,
  pathIndexTable?: readonly number[],
  pathPatterns: ReadonlyMap<number, string> = pathHashReverseLookup,
  syncSequence = false,
  rows: RowDecoding = { negotiated: false }
): StateUpdate {
  if (payload.length < 1) {
    throw new Error(`Unknown message format: empty payload`)
  }

  const updateType = (() => {
    switch (payload[0]) {
      case StateUpdateOpcode.noChange:
        return 'noChange' as const
      case StateUpdateOpcode.firstSync:
        return 'firstSync' as const
      case StateUpdateOpcode.diff:
        return 'diff' as const
      case StateUpdateOpcode.resync:
        if (!syncSequence) return null
        return 'resync' as const
      default:
        return null
    }
  })()

  if (!updateType) {
    throw new Error(`Unknown message format: ${JSON.stringify(payload).substring(0, 100)}`)
  }
  
  // Reset dynamic key map on first sync, and on a resync, which defines every key again
  if ((updateType === 'firstSync' || updateType === 'resync') && dynamicKeyMap) {
    dynamicKeyMap.clear()
  }
  // A resync's snapshot holds every row again, as creates. A firstSync that is a key-scope reset
  // keeps the row tables: slots aren't per key scope.
  if (updateType === 'resync') {
    rows.tables?.clear()
  }

  // Validate opcode format
  if (typeof payload[0] !== 'number') {
    throw new Error(`Unknown message format: expected opcode number at index 0`)
  }

  // With the syncSequence feature negotiated, index 1 is the land's sync sequence; otherwise
  // every entry after the opcode is a patch. The format follows the negotiation, never the shape.
  let seq: number | undefined
  if (syncSequence) {
    const raw = payload[1]
    if (typeof raw === 'number' && Number.isSafeInteger(raw) && raw >= 0) {
      seq = raw
    } else if (typeof raw === 'bigint' && raw >= 0n && raw <= BigInt(Number.MAX_SAFE_INTEGER)) {
      seq = Number(raw)
    } else {
      throw new Error(`Unknown message format: invalid sync sequence ${String(raw)}`)
    }
  }
  const patchStartIndex = syncSequence ? 2 : 1
  const patches: StatePatch[] = []
  const rowPatchIndices: number[] = []

  for (const entry of payload.slice(patchStartIndex)) {
    if (!Array.isArray(entry) || entry.length < 2) {
      throw new Error(`Unknown message format: ${JSON.stringify(payload).substring(0, 100)}`)
    }

    // Detect format:
    // Legacy: [path(string), op, value?]
    // PathHash: [pathHash(number), dynamicKey(string|number|[number,string]|null), op, value?]
    const firstElement = entry[0]
    const isPathHashFormat = typeof firstElement === 'number'

    let path: string
    let opCode: number
    let value: any

    if (isPathHashFormat) {
      // PathHash format: [pathHash, dynamicKey, op, value?]
      const [pathHash, rawDynamicKey, op, val] = entry
      
      if (typeof pathHash !== 'number') {
        throw new Error(`Invalid PathHash format: expected number, got ${typeof pathHash}`)
      }

      // A row entry's entry[1] is a slot or a slot list, not dynamic keys: the op is read first,
      // and no key is resolved or defined for it.
      const rowOp = exactCount(op, INT32_MAX)
      if (rowOp !== undefined && rowOp >= RowPatchOpcode.create && rowOp <= RowPatchOpcode.columnClear) {
        if (!rows.negotiated) {
          throw new RowEntryProtocolError(`op ${rowOp} without rowAddressing negotiated`)
        }
        if (!rows.tables) {
          throw new RowEntryProtocolError('no row tables for this connection')
        }
        if (!pathIndexTable) {
          throw new RowEntryProtocolError('rowAddressing without pathIndex')
        }
        const rowHash = hashAtPathIndex(pathIndexTable, pathHash)
        for (const patch of decodeRowEntry(entry, rowHash, rowOp, rows.tables, pathPatterns)) {
          rowPatchIndices.push(patches.length)
          patches.push(patch)
        }
        continue
      }

      // Resolve dynamic keys (supports multi-wildcard patterns).
      const resolveOneDynamicKey = (raw: unknown): string | null => {
        if (raw === null) return null
        if (typeof raw === 'string') return raw
        if (typeof raw === 'number') {
          if (dynamicKeyMap) {
            // `""` is a key (an empty map key), so look the slot up, don't test the key's truthiness.
            const key = dynamicKeyMap.has(raw) ? dynamicKeyMap.get(raw)! : null
            if (key === null) {
              throw new Error(`Dynamic key slot ${raw} used before definition`)
            }
            return key
          }
          // Fallback: treat as number string when no map is provided
          return String(raw)
        }
        if (Array.isArray(raw) && raw.length === 2) {
          const [slot, key] = raw
          if (typeof slot === 'number' && typeof key === 'string') {
            if (dynamicKeyMap) dynamicKeyMap.set(slot, key)
            return key
          }
          throw new Error(`Invalid dynamic key definition format: ${JSON.stringify(raw)}`)
        }
        throw new Error(`Invalid dynamic key format: ${JSON.stringify(raw)}`)
      }

      let dynamicKeys: string[] = []
      if (Array.isArray(rawDynamicKey)) {
        // Ambiguity: [slot, "key"] is a single-key definition, but [key1, key2] is multi-key.
        // Treat as a single-key definition ONLY when it matches [number, string].
        const isSingleKeyDefinition =
          rawDynamicKey.length === 2 &&
          typeof rawDynamicKey[0] === 'number' &&
          typeof rawDynamicKey[1] === 'string'

        if (isSingleKeyDefinition) {
          const one = resolveOneDynamicKey(rawDynamicKey)
          if (one !== null) dynamicKeys = [one]
        } else {
          // Multi-key form: [key0, key1, ...] where each key can be slot/definition/string/null.
          dynamicKeys = rawDynamicKey
            .map(k => resolveOneDynamicKey(k))
            .filter((k): k is string => k !== null)
        }
      } else {
        const one = resolveOneDynamicKey(rawDynamicKey)
        if (one !== null) dynamicKeys = [one]
      }
      
      const hash = pathIndexTable ? hashAtPathIndex(pathIndexTable, pathHash) : pathHash
      if (op === MergedPatchOpcode.set || op === MergedPatchOpcode.add) {
        patches.push(...decodeMergedEntry(entry, hash, dynamicKeys, op, pathPatterns))
        continue
      }

      // Reconstruct path from hash + dynamicKeys
      path = reconstructPath(hash, dynamicKeys, pathPatterns)
      opCode = op
      value = val
    } else {
      // Legacy format: [path, op, value?]
      const [pathStr, op, val] = entry
      
      if (typeof pathStr !== 'string') {
        throw new Error(`Unknown message format: ${JSON.stringify(payload).substring(0, 100)}`)
      }
      
      path = pathStr
      opCode = op
      value = val
    }

    let op: StatePatch['op']
    switch (opCode) {
      case StatePatchOpcode.replace:
        op = 'replace'
        break
      case StatePatchOpcode.remove:
        op = 'remove'
        break
      case StatePatchOpcode.add:
        op = 'add'
        break
      default:
        throw new Error(`Unknown message format: ${JSON.stringify(payload).substring(0, 100)}`)
    }

    const patch: StatePatch = { path, op }
    if (op !== 'remove' && value !== undefined) {
      patch.value = value
    }
    patches.push(patch)
  }

  const update: StateUpdate = seq === undefined ? { type: updateType, patches } : { type: updateType, patches, seq }
  if (rowPatchIndices.length > 0) {
    Object.defineProperty(update, ROW_PATCH_INDICES, { value: rowPatchIndices, enumerable: false })
  }
  return update
}

const rowTableOfPatternCache = new WeakMap<ReadonlyMap<number, string>, Map<string, number>>()

/** Pattern → hash for `patterns`, cached per connection's pattern map (it doesn't change). */
function hashOfPatternIn(patterns: ReadonlyMap<number, string>): Map<string, number> {
  const cached = patterns === pathHashReverseLookup ? undefined : rowTableOfPatternCache.get(patterns)
  if (cached) return cached
  const result = new Map<string, number>()
  for (const [hash, pattern] of patterns) result.set(pattern, hash)
  if (patterns !== pathHashReverseLookup) rowTableOfPatternCache.set(patterns, result)
  return result
}

/**
 * A row entry's patches, at the paths today's entries would name: a create is the set of the
 * row, a delete its removal, a column one set or one removal per slot. The rules and messages
 * follow the Swift decoder (`StateUpdateDecoder.decodeRowEntry`). Strict: a violation throws
 * `RowEntryProtocolError`, and the frame's earlier row entries stay applied to the tables.
 */
function decodeRowEntry(
  entry: unknown[],
  pathHash: number,
  op: number,
  tables: RowTables,
  patterns: ReadonlyMap<number, string>
): StatePatch[] {
  const pattern = patterns.get(pathHash)
  if (pattern === undefined) {
    throw new RowEntryProtocolError(`Unknown pathHash: ${pathHash}`)
  }
  // The table is the pattern up to its first dynamic key; a leaf's pattern has no other one.
  const components = pattern.split('.')
  const keyAt = components.indexOf('*')
  const table = keyAt < 0 || components.slice(keyAt + 1).includes('*')
    ? undefined
    : hashOfPatternIn(patterns).get(components.slice(0, keyAt + 1).join('.'))
  if (table === undefined) {
    throw new RowEntryProtocolError(`Row entry at ${pattern}, which is not a row or a leaf of one`)
  }
  const slots = (): number[] => {
    const raw = entry[1]
    if (!Array.isArray(raw)) {
      throw new RowEntryProtocolError('Column entry without a slot list')
    }
    const slots = raw.map((s) => exactCount(s, INT32_MAX))
    if (slots.length === 0 || slots.some((s, i) => s === undefined || (i > 0 && s <= slots[i - 1]!))) {
      throw new RowEntryProtocolError('Column entry: slots are not ascending integers')
    }
    return slots as number[]
  }
  const rowKey = (slot: number): string => {
    const key = tables.key(table, slot)
    if (key === undefined) {
      throw new RowEntryProtocolError(`Row entry on unbound slot ${slot} of ${pattern}`)
    }
    return key
  }
  switch (op) {
    case RowPatchOpcode.create:
    case RowPatchOpcode.delete: {
      const slot = exactCount(entry[1], INT32_MAX)
      if (pathHash !== table || slot === undefined) {
        throw new RowEntryProtocolError(`Row create or delete at ${pattern} without a slot`)
      }
      if (op === RowPatchOpcode.delete) {
        if (entry.length !== 3) {
          throw new RowEntryProtocolError('Row delete must not include a value')
        }
        const path = reconstructPath(pathHash, [rowKey(slot)], patterns)
        tables.unbind(table, slot)
        return [{ path, op: 'remove' }]
      }
      // [tableId, slot, 6, generation, parentSlot, key, value]
      const generation = exactCount(entry[3], UINT32_MAX)
      const key = entry[5]
      if (entry.length !== 7 || generation === undefined || entry[4] !== null || typeof key !== 'string') {
        throw new RowEntryProtocolError('Invalid row create entry')
      }
      if (tables.key(table, slot) !== undefined) {
        throw new RowEntryProtocolError(`Row create on bound slot ${slot} of ${pattern}`)
      }
      const last = tables.lastGeneration(table, slot)
      if (last !== undefined && generation <= last) {
        throw new RowEntryProtocolError(`Row create on slot ${slot} of ${pattern}: generation ${generation} after ${last}`)
      }
      const path = reconstructPath(pathHash, [key], patterns)
      tables.bind(table, slot, key, generation)
      return [{ path, op: 'replace', value: entry[6] }]
    }
    case RowPatchOpcode.columnSet: {
      const values = entry[3]
      if (pathHash === table || entry.length !== 4 || !Array.isArray(values)) {
        throw new RowEntryProtocolError('Invalid column set entry')
      }
      const columnSlots = slots()
      if (values.length !== columnSlots.length) {
        throw new RowEntryProtocolError(`Column set: ${columnSlots.length} slots for ${values.length} values`)
      }
      return columnSlots.map((slot, i) => ({ path: reconstructPath(pathHash, [rowKey(slot)], patterns), op: 'replace' as const, value: values[i] }))
    }
    default: {
      if (pathHash === table || entry.length !== 3) {
        throw new RowEntryProtocolError('Invalid column clear entry')
      }
      return slots().map((slot) => ({ path: reconstructPath(pathHash, [rowKey(slot)], patterns), op: 'remove' as const }))
    }
  }
}

/** A merged entry's patches: the parent's field at each mask bit, in ascending bit order. */
function decodeMergedEntry(
  entry: unknown[],
  parentHash: number,
  dynamicKeys: string[],
  op: number,
  patterns: ReadonlyMap<number, string>
): StatePatch[] {
  const mask = entry[3]
  const values = entry.slice(4)
  if (typeof mask !== 'number' || !Number.isInteger(mask) || mask <= 0 || mask > 0xffffffff) {
    throw new Error(`Merged entry: invalid field mask ${JSON.stringify(mask)}`)
  }
  const bits: number[] = []
  for (let bit = 0; bit < FIELD_MERGE_MAX_FIELDS; bit += 1) {
    if (Math.floor(mask / 2 ** bit) % 2 === 1) bits.push(bit)
  }
  if (bits.length !== values.length) {
    throw new Error(`Merged entry: mask ${mask} for ${values.length} values`)
  }
  const children = fieldMergeChildrenOf(patterns).get(parentHash)
  return bits.map((bit, i) => {
    const childHash = children?.[bit]
    if (childHash === undefined) {
      throw new Error(`Unknown merged field: bit ${bit} of pathHash ${parentHash}`)
    }
    const patch: StatePatch = { path: reconstructPath(childHash, dynamicKeys, patterns), op: op === MergedPatchOpcode.set ? 'replace' : 'add' }
    patch.value = values[i]
    return patch
  })
}

/** The widest merged-entry mask: 32 bits (Swift `FieldMergeTable.maxFields`). */
const FIELD_MERGE_MAX_FIELDS = 32

/** Strings in UTF-8 byte order (Swift's `FieldMergeTable` sorts field names so). */
function compareUtf8(a: string, b: string): number {
  const x = utf8Encoder.encode(a)
  const y = utf8Encoder.encode(b)
  const n = Math.min(x.length, y.length)
  for (let i = 0; i < n; i += 1) {
    if (x[i] !== y[i]) return x[i] - y[i]
  }
  return x.length - y.length
}
const utf8Encoder = new TextEncoder()

const fieldMergeChildrenCache = new WeakMap<ReadonlyMap<number, string>, Map<number, number[]>>()

/**
 * Each parent pattern's hash → its named children's hashes by bit: patterns `parent.<name>`
 * (name not `*`, parent a pattern too), sorted by name in byte order, the first 32. Cached per
 * connection's pattern map, which doesn't change; the global lookup is refilled per schema.
 */
export function fieldMergeChildrenOf(patterns: ReadonlyMap<number, string>): Map<number, number[]> {
  const cached = patterns === pathHashReverseLookup ? undefined : fieldMergeChildrenCache.get(patterns)
  if (cached) return cached
  const hashOfPattern = new Map<string, number>()
  for (const [hash, pattern] of patterns) hashOfPattern.set(pattern, hash)
  const named = new Map<string, string[]>()
  for (const pattern of hashOfPattern.keys()) {
    const dot = pattern.lastIndexOf('.')
    if (dot < 0) continue
    const parent = pattern.slice(0, dot)
    const name = pattern.slice(dot + 1)
    if (name === '*' || !hashOfPattern.has(parent)) continue
    const names = named.get(parent) ?? []
    names.push(name)
    named.set(parent, names)
  }
  const children = new Map<number, number[]>()
  for (const [parent, names] of named) {
    names.sort(compareUtf8)
    children.set(hashOfPattern.get(parent)!, names.slice(0, FIELD_MERGE_MAX_FIELDS).map((name) => hashOfPattern.get(`${parent}.${name}`)!))
  }
  if (patterns !== pathHashReverseLookup) fieldMergeChildrenCache.set(patterns, children)
  return children
}

/**
 * Reconstruct full JSON Pointer path from pathHash and dynamicKey
 * Uses global pathHashReverseLookup (set during schema initialization)
 */
function reconstructPath(
  pathHash: number,
  dynamicKeys: string[],
  patterns: ReadonlyMap<number, string> = pathHashReverseLookup
): string {
  const pattern = patterns.get(pathHash)
  if (!pattern) {
    // More descriptive error message for debugging
    const availableHashes = Array.from(patterns.keys()).slice(0, 10).join(', ')
    throw new Error(`Unknown pathHash: ${pathHash}. Ensure schema is loaded. Available hashes (first 10): ${availableHashes}. Lookup table size: ${patterns.size}`)
  }
  
  // Replace wildcards with dynamic keys (in order)
  if (pattern.includes('*') && dynamicKeys.length > 0) {
    let i = 0
    const pathPattern = pattern.replace(/\*/g, (m) => {
      if (i >= dynamicKeys.length) return m
      return dynamicKeys[i++]
    })
    return '/' + pathPattern.replace(/\./g, '/')
  }
  
  // No dynamic key (static path)
  return '/' + pattern.replace(/\./g, '/')
}

// Global reverse lookup table (hash → path pattern)
// Populated by View during schema initialization
export const pathHashReverseLookup = new Map<number, string>()

/** Fills `pathHashReverseLookup` from a land's schema `pathHashes`. */
export function setPathHashes(pathHashes: Record<string, number>): void {
  pathHashReverseLookup.clear()
  for (const [pattern, hash] of Object.entries(pathHashes)) {
    pathHashReverseLookup.set(hash, pattern)
  }
}

/**
 * A land's rank table: its schema `pathHashes` values, de-duplicated and sorted ascending. A path
 * index is a position here. Per land, so it is held per connection (`pathIndexTable`), not
 * globally: a hash maps to its pattern in every land, an index only in its own.
 */
export function pathIndexTableFor(pathHashes: Record<string, number>): number[] {
  return [...new Set(Object.values(pathHashes))].sort((a, b) => a - b)
}

function hashAtPathIndex(table: readonly number[], index: number): number {
  const hash = Number.isInteger(index) && index >= 0 ? table[index] : undefined
  if (hash === undefined) {
    throw new Error(`Unknown path index: ${index}. Path index table size: ${table.length}`)
  }
  return hash
}

/**
 * State-update feature names, declared in join metadata (`stateUpdateFeatures`) and echoed by
 * the server in `joinResponse`.
 */
export const StateUpdateFeatures = {
  pathIndex: 'pathIndex',
  fieldMerge: 'fieldMerge',
  syncSequence: 'syncSequence',
  /**
   * Row entries (ops 6–9) for slot-addressed tables. Decoded when the join response names it;
   * not declared in `SUPPORTED_STATE_UPDATE_FEATURES` until the runtime keeps row tables.
   */
  rowAddressing: 'rowAddressing'
} as const

/** The state-update features this SDK decodes; sent with every join. */
export const SUPPORTED_STATE_UPDATE_FEATURES: string[] = [
  StateUpdateFeatures.pathIndex,
  StateUpdateFeatures.fieldMerge,
  StateUpdateFeatures.syncSequence
]

export interface JoinOptions {
  playerID?: string
  deviceID?: string
  metadata?: Record<string, any>
}

/**
 * Create a join message
 * MessagePayload encodes as { "join": TransportJoinPayload }
 * 
 * @param requestID - Unique request identifier
 * @param landType - The type of Land to join (required)
 * @param landInstanceId - The specific instance to join (optional, if null a new room will be created)
 * @param options - Optional join options (playerID, deviceID, metadata)
 */
export function createJoinMessage(
  requestID: string,
  landType: string,
  landInstanceId: string | null | undefined,
  options?: JoinOptions
): TransportMessage {
  return {
    kind: 'join',
    payload: {
      join: {
        requestID,
        landType,
        landInstanceId: landInstanceId ?? null,
        playerID: options?.playerID,
        deviceID: options?.deviceID,
        metadata: options?.metadata
      }
    } as any // Type assertion needed because payload is a union type
  }
}

/**
 * Create an action message
 * MessagePayload encodes as { "action": TransportActionPayload }
 */
export function createActionMessage(
  requestID: string,
  actionType: string,
  payload: any
): TransportMessage {
  // Use JSON object directly (same as Event payload)
  // Simplified structure: directly use requestID, typeIdentifier, payload in payload
  return {
    kind: 'action',
    payload: {
      requestID,
      typeIdentifier: actionType,
      payload: payload || {}
    } as any // Type assertion needed because payload is a union type
  }
}

/**
 * Create an event message
 * MessagePayload encodes as { "event": TransportEventPayload }
 */
export function createEventMessage(
  eventType: string,
  payload: any,
  fromClient: boolean = true
): TransportMessage {
  // Simplified structure: directly use fromClient/fromServer in payload
  return {
    kind: 'event',
    payload: fromClient
      ? {
          fromClient: {
            type: eventType,
            payload: payload || {}
          }
        } as any
      : {
          fromServer: {
            type: eventType,
            payload: payload || {}
          }
        } as any
  }
}

// Client-side request ID counter (only needs to be unique within a single client instance)
let requestIDCounter = 0

/**
 * Generate a unique request ID
 * 
 * Uses a simple counter since requestID only needs to be unique within a single client instance.
 * The server just echoes it back in the response for matching.
 */
export function generateRequestID(prefix: string = 'req'): string {
  requestIDCounter++
  // Use counter for minimal size (e.g., "req-1", "req-2")
  // Prefix is optional but useful for debugging
  return prefix ? `${prefix}-${requestIDCounter}` : String(requestIDCounter)
}

// MARK: - TransportMessage Opcode Decoding

/**
 * Map from opcode number to MessageKind.
 * Uses 101+ range to avoid conflict with StateUpdateOpcode (0-2).
 */
const MESSAGE_OPCODE_TO_KIND: Record<number, import('../types/transport').MessageKind> = {
  [MessageKindOpcode.action]: 'action',
  [MessageKindOpcode.actionResponse]: 'actionResponse',
  [MessageKindOpcode.event]: 'event',
  [MessageKindOpcode.join]: 'join',
  [MessageKindOpcode.joinResponse]: 'joinResponse',
  [MessageKindOpcode.error]: 'error'
}

/**
 * Check if an opcode is a TransportMessage opcode (101-106)
 */
export function isTransportMessageOpcode(opcode: number): boolean {
  return opcode >= MessageKindOpcode.action && opcode <= MessageKindOpcode.error
}

/**
 * Decode a JSON array to TransportMessage (opcode format)
 * 
 * Formats:
 * - joinResponse: [MessageKindOpcode.joinResponse, requestID, success(0/1), landType?, landInstanceId?, playerSlot?, encoding?, reason?, stateUpdateFeatures?]
 * - actionResponse: [MessageKindOpcode.actionResponse, requestID, response]
 * - error: [MessageKindOpcode.error, code, message, details?]
 * - action: [MessageKindOpcode.action, requestID, typeIdentifier, payload(object)]
 * - join: [MessageKindOpcode.join, requestID, landType, landInstanceId?, playerID?, deviceID?, metadata?]
 * - event: [MessageKindOpcode.event, direction(EventDirection.fromClient/fromServer), type, payload, rawBody?]
 */
export function decodeTransportMessageArray(payload: unknown[]): TransportMessage {
  if (payload.length < 2) {
    throw new Error(`Invalid TransportMessage opcode array: too short: ${JSON.stringify(payload).substring(0, 100)}`)
  }
  
  const opcode = payload[0] as number
  const kind = MESSAGE_OPCODE_TO_KIND[opcode]
  
  if (!kind) {
    throw new Error(`Unknown TransportMessage opcode: ${opcode}`)
  }
  
  switch (kind) {
    case 'joinResponse':
      return decodeJoinResponseArray(payload)
    case 'actionResponse':
      return decodeActionResponseArray(payload)
    case 'error':
      return decodeErrorArray(payload)
    case 'action':
      return decodeActionArray(payload)
    case 'join':
      return decodeJoinArray(payload)
    case 'event':
      return decodeEventArray(payload)
    default:
      throw new Error(`Unsupported TransportMessage kind: ${kind}`)
  }
}

// [MessageKindOpcode.joinResponse, requestID, success(0/1), landType?, landInstanceId?, playerSlot?, encoding?, reason?, stateUpdateFeatures?]
function decodeJoinResponseArray(payload: unknown[]): TransportMessage {
  const requestID = payload[1] as string
  const success = payload[2] === 1
  const landType = payload[3] as string | null | undefined
  const landInstanceId = payload[4] as string | null | undefined
  const playerSlot = payload[5] as number | null | undefined
  const encoding = payload[6] as string | null | undefined
  const reason = payload[7] as string | null | undefined
  const stateUpdateFeatures = payload[8] as string[] | null | undefined
  
  return {
    kind: 'joinResponse',
    payload: {
      joinResponse: {
        requestID,
        success,
        landType: landType ?? undefined,
        landInstanceId: landInstanceId ?? undefined,
        landID: landType && landInstanceId ? `${landType}:${landInstanceId}` : undefined,
        playerSlot: playerSlot ?? undefined,
        encoding: encoding ?? undefined,
        reason: reason ?? undefined,
        stateUpdateFeatures: stateUpdateFeatures ?? undefined
      }
    }
  } as TransportMessage
}

// [MessageKindOpcode.actionResponse, requestID, response]
function decodeActionResponseArray(payload: unknown[]): TransportMessage {
  const requestID = payload[1] as string
  const response = payload[2]
  
  return {
    kind: 'actionResponse',
    payload: {
      actionResponse: {
        requestID,
        response
      }
    }
  } as TransportMessage
}

// [MessageKindOpcode.error, code, message, details?]
function decodeErrorArray(payload: unknown[]): TransportMessage {
  const code = payload[1] as string
  const message = payload[2] as string
  const details = payload[3] as Record<string, any> | undefined
  
  return {
    kind: 'error',
    payload: {
      error: {
        code,
        message,
        details
      }
    }
  } as TransportMessage
}

// [MessageKindOpcode.action, requestID, typeIdentifier, payload(object)]
function decodeActionArray(payload: unknown[]): TransportMessage {
  const requestID = payload[1] as string
  const typeIdentifier = payload[2] as string
  const actionPayload = payload[3] as any || {}
  
  return {
    kind: 'action',
    payload: {
      requestID,
      typeIdentifier,
      payload: actionPayload
    }
  } as TransportMessage
}

// [MessageKindOpcode.join, requestID, landType, landInstanceId?, playerID?, deviceID?, metadata?]
function decodeJoinArray(payload: unknown[]): TransportMessage {
  const requestID = payload[1] as string
  const landType = payload[2] as string
  const landInstanceId = payload[3] as string | null | undefined
  const playerID = payload[4] as string | null | undefined
  const deviceID = payload[5] as string | null | undefined
  const metadata = payload[6] as Record<string, any> | null | undefined
  
  return {
    kind: 'join',
    payload: {
      join: {
        requestID,
        landType,
        landInstanceId: landInstanceId ?? undefined,
        playerID: playerID ?? undefined,
        deviceID: deviceID ?? undefined,
        metadata: metadata ?? undefined
      }
    }
  } as TransportMessage
}

// [107, stateUpdatePayload, eventsArray] where eventsArray is [[direction, type, payload], ...]
function decodeStateUpdateWithEventsArray(
  payload: unknown[],
  dynamicKeyMap?: Map<number, string>,
  pathIndexTable?: readonly number[],
  pathPatterns?: ReadonlyMap<number, string>,
  syncSequence = false,
  rows: RowDecoding = { negotiated: false }
): StateUpdateWithEvents {
  if (payload.length < 3) {
    throw new Error(`Invalid opcode 107 payload: expected [107, statePayload, eventsArray], got ${payload.length} elements`)
  }
  const statePayload = payload[1] as unknown[]
  const eventsList = payload[2] as unknown[]
  const stateUpdate = decodeStateUpdateArray(statePayload, dynamicKeyMap, pathIndexTable, pathPatterns, syncSequence, rows)
  const events: TransportMessage[] = []
  if (Array.isArray(eventsList)) {
    for (const entry of eventsList) {
      if (!Array.isArray(entry)) continue
      // Event body is [direction, type, payload, rawBody?]; prepend opcode 103 for decodeEventArray
      const fullEventArray = [MessageKindOpcode.event, ...entry]
      events.push(decodeEventArray(fullEventArray))
    }
  }
  return { type: 'stateUpdateWithEvents', stateUpdate, events }
}

// [MessageKindOpcode.event, direction(EventDirection.fromClient/fromServer), type, payload, rawBody?]
function decodeEventArray(payload: unknown[]): TransportMessage {
  const direction = payload[1] as number
  const rawType = payload[2]
  const rawPayload = payload[3]
  const rawBody = payload[4]
  
  let type: string
  if (typeof rawType === 'number') {
    // Resolve opcode
    const lookup = direction === EventDirection.fromClient ? clientEventHashReverseLookup : eventHashReverseLookup
    const resolved = lookup.get(rawType)
    if (!resolved) {
        throw new Error(`Unknown event opcode: ${rawType} (direction: ${direction})`)
    }
    type = resolved
  } else {
    type = rawType as string
  }

  // Handle Array Payload (Compressed)
  let eventPayload = rawPayload
  if (Array.isArray(rawPayload)) {
    // Reconstruct object from array using field order
    // Use type string for lookup (as we might not interpret opcode in future phases or fallback)
    // Actually, looking up by type name is safest as it works for both opcode and string sources.
    const fieldOrderMap = direction === EventDirection.fromClient ? clientEventFieldOrder : eventFieldOrder
    const fieldOrder = fieldOrderMap.get(type)
    
    protocolLogger.debug(`COMPRESSED_PAYLOAD: Decoding array payload for event '${type}' (Length: ${rawPayload.length})`)

    if (!fieldOrder) {
        // Warning or Error? If we receive an array but don't know the schema, we can't decode.
        // But maybe it's just an empty array for an empty event?
        // If array is empty and fieldOrder is missing/empty, it's fine.
        if (rawPayload.length > 0) {
           console.warn(`[Compression] Received array payload for event '${type}' but no field order found. Payload may be corrupt.`)
        }
        eventPayload = {}
    } else {
        const payloadObj: Record<string, any> = {}
        // Map values to keys
        // Note: rawPayload length might be shorter than fieldOrder if trailing optionals are omitted (not implemented in server yet, server sends all? Server sends based on Mirror children).
        // Swift Mirror children includes optionals.
        // Server sends [AnyCodable].
        fieldOrder.forEach((key, index) => {
            if (index < rawPayload.length) {
                payloadObj[key] = rawPayload[index]
            }
        })
        eventPayload = payloadObj
    }
  } else if (rawPayload && typeof rawPayload === 'object') {
    // Payload is already an object (not compressed array)
    // Use it as-is, but validate structure
    eventPayload = rawPayload
  }
  
  if (direction === EventDirection.fromClient) {
    // fromClient
    return {
      kind: 'event',
      payload: {
        fromClient: {
          type,
          payload: eventPayload,
          rawBody
        }
      }
    } as TransportMessage
  } else {
    // fromServer
    return {
      kind: 'event',
      payload: {
        fromServer: {
          type,
          payload: eventPayload,
          rawBody
        }
      }
    } as TransportMessage
  }
}

// Global reverse lookup tables (hash → event type)
// Populated by View during schema initialization
export const eventHashReverseLookup = new Map<number, string>()
export const clientEventHashReverseLookup = new Map<number, string>()

// Global forward lookup tables (event type → hash)
// Populated by View during schema initialization
export const eventHashLookup = new Map<string, number>()
export const clientEventHashLookup = new Map<string, number>()

// Global field order tables (event type → field keys[])
// Populated by View during schema initialization
export const eventFieldOrder = new Map<string, string[]>()
export const clientEventFieldOrder = new Map<string, string[]>()

// Global action field order table (action type → field keys[])
// Populated by View during schema initialization
export const actionFieldOrder = new Map<string, string[]>()
