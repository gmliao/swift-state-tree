import type { TransportMessage, StateUpdate, StateSnapshot, StateUpdateWithEvents, TransportEncodingConfig, MessageEncoding } from '../types/transport'
import { MessageEncodingValues, StateUpdateEncodingValues } from '../types/transport'
import { createWebSocket, type WebSocketConnection } from './websocket'
import { decodeMessage, encodeMessageToFormat, encodeSyncAck, StateUpdateFeatures } from './protocol'
import { NoOpLogger, type Logger } from './logger'
import { StateTreeView, type ViewOptions } from './view'
import { ConnectionClosedError } from './errors'

export interface RuntimeOptions {
  logger?: Logger
  transportEncoding?: TransportEncodingConfig
  /**
   * How often the runtime acks the last applied sync sequence (#332), when the server sends one.
   * Well below the server's ack timeout (10 s by default). Default 1000; at least 50, or the
   * constructor throws a `RangeError`.
   */
  ackIntervalMs?: number
}

const DEFAULT_ACK_INTERVAL_MS = 1000
const MIN_ACK_INTERVAL_MS = 50

/**
 * StateTreeRuntime - Manages WebSocket connection and routes messages to Views
 * 
 * Responsibilities:
 * - WebSocket connection management
 * - Protocol message encoding/decoding
 * - Message routing to Views
 * - Connection lifecycle management
 */
/**
 * Statistics callback for tracking message traffic
 * Used to report actual WebSocket message sizes for accurate traffic monitoring
 */
export interface MessageStatistics {
  messageType: 'stateUpdate' | 'stateSnapshot' | 'transportMessage'
  messageSize: number // Actual bytes (raw WebSocket message size)
  direction: 'inbound' | 'outbound' // Whether message is received or sent
  patchCount?: number // Number of patches (for StateUpdate)
}

export type StatisticsCallback = (stats: MessageStatistics) => void

/** Decode failures of one runtime (`StateTreeRuntime.decodeErrorStats`). */
export interface DecodeErrorStats {
  /** Messages that failed to decode before `disconnect()`. */
  beforeLeave: number
  /**
   * Messages that failed to decode after `disconnect()` (#190): frames received before it whose
   * decode finished after it. Frames that arrive on the dropped socket are ignored (#143).
   */
  afterLeave: number
  /** The first few errors, prefixed with when they happened. */
  samples: string[]
}

const DECODE_ERROR_SAMPLE_LIMIT = 5

export class StateTreeRuntime {
  private ws: WebSocketConnection | null = null
  private isConnected = false
  /** The connect in progress (#143): a second `connect()` to the same URL joins it. */
  private connecting: { url: string; promise: Promise<void>; abort: (error: Error) => void } | null = null
  /** Bumped by every `connect()` and `disconnect()`; a connect whose socket arrives late checks it. */
  private connectGeneration = 0
  private views = new Map<string, StateTreeView>()
  private logger: Logger
  private transportEncoding: TransportEncodingConfig
  private onDisconnectCallback: ((code: number, reason: string, wasClean: boolean) => void) | null = null
  private statisticsCallback: StatisticsCallback | null = null
  /** The last sync sequence applied on this connection; none before its first sequenced update. */
  private lastAppliedSeq: number | undefined
  private lastAckSentAt = 0
  private ackTimer: ReturnType<typeof setInterval> | null = null
  private ackIntervalMs = DEFAULT_ACK_INTERVAL_MS
  /** The sequence of the last resync applied (#332): later frames with it skip their patches. */
  private resyncSeq: number | undefined
  
  // Mapping for dynamic key compression (Slot ID -> Original Key)
  // Broadcast and per-player scopes are tracked separately.
  private broadcastDynamicKeyMap = new Map<number, string>()
  /** Messages that failed to decode, split at `disconnect()` (see `decodeErrorStats`). */
  private decodeErrors: DecodeErrorStats = { beforeLeave: 0, afterLeave: 0, samples: [] }
  /** Set by `disconnect()`: later decode errors count as `afterLeave`. */
  private leaving = false
  private perPlayerDynamicKeyMap = new Map<number, string>()
  
  /**
   * Determine StateUpdate encoding based on Message encoding
   * 
   * Protocol mapping:
   * - json message encoding → jsonObject stateUpdate encoding
   * - opcodeJsonArray message encoding → opcodeJsonArray stateUpdate encoding
   * - messagepack message encoding → opcodeJsonArray stateUpdate encoding (MessagePack uses opcode array format)
   */
  private static getStateUpdateEncoding(messageEncoding: MessageEncoding): 'jsonObject' | 'opcodeJsonArray' {
    switch (messageEncoding) {
      case MessageEncodingValues.json:
        return StateUpdateEncodingValues.jsonObject
      case MessageEncodingValues.opcodeJsonArray:
      case MessageEncodingValues.messagepack:
        return StateUpdateEncodingValues.opcodeJsonArray
      default:
        // Fallback to opcodeJsonArray for unknown encodings
        return StateUpdateEncodingValues.opcodeJsonArray
    }
  }
  
  /**
   * Update decoding strategy based on encoding received from joinResponse
   * This allows Runtime to use the correct decoding path instead of trying multiple formats
   * @param encoding - The message encoding format from joinResponse
   */
  updateDecodingStrategy(encoding: MessageEncoding): void {
    // Update transportEncoding to use the known encoding format
    // This ensures decodeMessage uses the correct path instead of trying multiple formats
    // Preserve existing stateUpdateDecoding preference if set (don't override strict decoding preferences)
    const stateUpdateEncoding = StateTreeRuntime.getStateUpdateEncoding(encoding)
    this.transportEncoding = {
      ...this.transportEncoding,
      message: encoding,
      stateUpdate: stateUpdateEncoding,
      // Preserve existing stateUpdateDecoding if explicitly set, otherwise use 'auto'
      stateUpdateDecoding: this.transportEncoding.stateUpdateDecoding ?? 'auto'
    }
    this.logger.info(`Updated Runtime decoding strategy: message=${encoding}, stateUpdate=${stateUpdateEncoding}, stateUpdateDecoding=${this.transportEncoding.stateUpdateDecoding}`)
  }

  /**
   * Set the state-update features from joinResponse (`stateUpdateFeatures`) and the joined
   * land's rank table: with `pathIndex`, path ids in state updates are positions in that table
   * instead of hashes. A connection is bound to one land, so the table is this runtime's.
   */
  updateStateUpdateFeatures(
    features: string[],
    pathIndexTable?: readonly number[],
    pathPatterns?: ReadonlyMap<number, string>
  ): void {
    this.transportEncoding = { ...this.transportEncoding, stateUpdateFeatures: [...features], pathIndexTable, pathPatterns }
    this.logger.info(`Updated state-update features: [${features.join(', ')}]`)
    this.stopAcks()
    if (features.includes(StateUpdateFeatures.syncSequence)) {
      // Sent even when the value hasn't changed: that is how the server tells "acks still
      // arrive" from "no ack".
      this.ackTimer = setInterval(() => this.sendAck(), this.ackIntervalMs)
      ;(this.ackTimer as any)?.unref?.()
    }
  }

  /**
   * A sequenced state update was applied: records its sequence, and acks at once after a full
   * view (firstSync or resync), or once an interval has passed since the last ack. The apply-path
   * ack keeps a busy connection fresh when the browser throttles the timer (a hidden tab).
   */
  /**
   * After a resync (#332), another state frame with the same sequence (the merged broadcast
   * frame the server sends after the snapshot) holds nothing the snapshot doesn't: its key
   * definitions are already read by the decoder and its events are dispatched, but its patches
   * are not applied. Applying them would notify changes the reconcile already made.
   */
  private coveredByResync(update: StateUpdate): boolean {
    return update.type !== 'resync' && update.seq !== undefined && update.seq === this.resyncSeq
  }

  private noteApplied(update: StateUpdate): void {
    if (update.type === 'resync' && update.seq !== undefined) this.resyncSeq = update.seq
    if (update.seq === undefined) return
    this.lastAppliedSeq = update.seq
    if (update.type === 'firstSync' || update.type === 'resync' || Date.now() - this.lastAckSentAt >= this.ackIntervalMs) {
      this.sendAck()
    }
  }

  /** Sends `[108, lastAppliedSeq]` in the connection's message encoding; nothing before it has one. */
  private sendAck(): void {
    const seq = this.lastAppliedSeq
    if (seq === undefined || !this.ws) return
    try {
      const encoded = encodeSyncAck(seq, this.transportEncoding.message)
      if (typeof encoded === 'string') {
        this.ws.send(encoded)
      } else {
        this.ws.send(encoded.buffer.slice(encoded.byteOffset, encoded.byteOffset + encoded.byteLength) as ArrayBuffer)
      }
      this.lastAckSentAt = Date.now()
    } catch (error) {
      this.logger.warn(`Sync ack not sent: ${String(error)}`)
    }
  }

  /** Stops the ack timer and forgets the connection's sequence. */
  private stopAcks(): void {
    if (this.ackTimer) {
      clearInterval(this.ackTimer)
      this.ackTimer = null
    }
    this.lastAppliedSeq = undefined
    this.resyncSeq = undefined
    this.lastAckSentAt = 0
  }

  constructor(options?: Logger | RuntimeOptions) {
    const resolved = resolveRuntimeOptions(options)
    this.logger = resolved.logger
    this.transportEncoding = resolved.transportEncoding
    if (options && !isLogger(options) && options.ackIntervalMs !== undefined) {
      const interval = options.ackIntervalMs
      // A zero, negative or non-finite interval would flood the server with acks.
      if (!Number.isFinite(interval) || interval < MIN_ACK_INTERVAL_MS) {
        throw new RangeError(`ackIntervalMs must be a finite number of at least ${MIN_ACK_INTERVAL_MS} ms, got ${interval}`)
      }
      this.ackIntervalMs = interval
    }
  }

  /**
   * Set callback for message statistics
   * @param callback - Called for each received message with statistics
   */
  setStatisticsCallback(callback: StatisticsCallback | null): void {
    this.statisticsCallback = callback
  }

  /**
   * Set callback for disconnection events
   * @param callback - Called when connection closes, receives close code, reason, and wasClean flag
   */
  onDisconnect(callback: (code: number, reason: string, wasClean: boolean) => void): void {
    this.onDisconnectCallback = callback
  }

  /**
   * Connect to WebSocket server
   * 
   * @throws {Error} If connection fails, the error will have `closeCode`, `closeReason`, and `wasClean` properties
   *                 if the failure occurred during WebSocket handshake (connection was closed before opening)
   */
  connect(url: string): Promise<void> {
    // Single flight (#143): a connect to the same URL while one is in progress shares its promise;
    // a different URL is refused instead of opening a second socket.
    if (this.connecting) {
      if (this.connecting.url === url) return this.connecting.promise
      return Promise.reject(new Error(`Already connecting to ${this.connecting.url}`))
    }
    if (this.isConnected) {
      return Promise.reject(new Error('Already connected'))
    }
    this.leaving = false
    const generation = ++this.connectGeneration

    let resolve!: () => void
    let reject!: (error: any) => void
    const promise = new Promise<void>((res, rej) => {
      resolve = res
      reject = rej
    })
    const attempt = { url, promise, abort: (error: Error) => reject(error) }
    this.connecting = attempt
    const finish = () => {
      if (this.connecting === attempt) this.connecting = null
    }
    promise.then(finish, finish)

    this.logger.info(`Connecting to ${url}...`)
    void (async () => {
      let socket: WebSocketConnection
      try {
        // Set binaryType to 'arraybuffer' for MessagePack binary support
        socket = await createWebSocket(url, { binaryType: 'arraybuffer' })
      } catch (error) {
        this.logger.error(`Failed to create WebSocket: ${error}`)
        reject(error)
        return
      }
      // disconnect() (or another connect after it) ran while the socket was being created: this
      // attempt was already rejected, so drop the socket instead of installing it.
      if (generation !== this.connectGeneration) {
        socket.close()
        return
      }
      this.ws = socket
      this.setupWebSocketHandlers(socket, resolve, reject)
    })()
    return promise
  }

  /**
   * Every handler first checks that its socket is still the current one (#143): a socket that
   * `disconnect()` dropped or a later `connect()` replaced must not touch the next connection.
   */
  private setupWebSocketHandlers(socket: WebSocketConnection, resolve: () => void, reject: (error: any) => void): void {

    let connectionResolved = false
    let closeCode: number | null = null
    let closeReason: string = ''
    let wasClean: boolean = false

    socket.onopen = () => {
      if (this.ws !== socket) return
      this.isConnected = true
      this.logger.info('WebSocket connected')
      // Reset dynamic key map on new connection
      this.broadcastDynamicKeyMap.clear()
      this.perPlayerDynamicKeyMap.clear()
      connectionResolved = true
      resolve()
    }

    socket.onerror = (event) => {
      if (this.ws !== socket) return
      // Note: onerror doesn't provide detailed error info in browsers
      // The actual error details will be in onclose event
      this.logger.error('WebSocket error event triggered')
      // Don't reject here - wait for onclose to get the actual error code and reason
    }

    socket.onclose = (event) => {
      // A socket that disconnect() already dropped or a later connect() replaced: its cleanup is
      // done, and the connection state, key maps and views now belong to the next connection.
      const isCurrent = this.ws === socket
      if (isCurrent) {
        this.isConnected = false
        this.stopAcks()
        this.broadcastDynamicKeyMap.clear()
        this.perPlayerDynamicKeyMap.clear()
      }
      closeCode = event.code
      closeReason = event.reason || 'No reason provided'
      wasClean = event.wasClean
      
      // Log close details
      if (closeCode !== 1000) { // 1000 is normal closure
        this.logger.error(`WebSocket closed: code=${closeCode}, reason=${closeReason}, wasClean=${wasClean}`)
      } else {
        this.logger.info(`WebSocket closed: code=${closeCode}, reason=${closeReason}`)
      }
      
      // If connection was never established (failed during handshake), reject the promise
      if (!connectionResolved) {
        // Create error with close code and reason
        // Format a user-friendly error message based on close code
        let errorMessage = `WebSocket connection failed`
        if (closeCode === 1008) {
          errorMessage = `Connection rejected (Policy Violation): ${closeReason || 'Possible JWT token validation failure'}`
        } else if (closeCode === 1006) {
          errorMessage = `Connection abnormally closed: ${closeReason || 'Possible network issue or server error'}`
        } else if (closeCode === 1011) {
          errorMessage = `Server internal error: ${closeReason || 'Server error while processing request'}`
        } else if (closeCode !== 1000) {
          errorMessage = `Connection failed (code=${closeCode}): ${closeReason || 'Unknown reason'}`
        }
        
        const error = new Error(errorMessage) as any
        error.closeCode = closeCode
        error.closeReason = closeReason
        error.wasClean = wasClean
        reject(error)
      }

      if (!isCurrent) return

      // Settle every pending request, then drop the views (#109)
      this.destroyAllViews(new ConnectionClosedError('close', { closeCode, closeReason, wasClean }))
      // Notify disconnect callback with close details
      if (this.onDisconnectCallback) {
        this.onDisconnectCallback(closeCode, closeReason, wasClean)
      }
    }

    socket.onmessage = (event) => {
      // A late frame from a dropped socket would be decoded against the next connection's key maps
      if (this.ws !== socket) return
      void this.handleMessage(event.data)
    }
  }

  /**
   * Disconnect from WebSocket server
   */
  disconnect(): void {
    this.leaving = true
    // Abort a connect in progress (#143): its socket is dropped when it arrives or closed here
    this.connectGeneration += 1
    const attempt = this.connecting
    this.connecting = null
    if (this.ws) {
      const socket = this.ws
      this.ws = null
      socket.close()
    }
    this.isConnected = false
    this.stopAcks()
    this.broadcastDynamicKeyMap.clear()
    this.perPlayerDynamicKeyMap.clear()
    // Settle every pending request, then drop the views (#109)
    this.destroyAllViews(new ConnectionClosedError('disconnect'))
    // Clear disconnect callback
    this.onDisconnectCallback = null
    attempt?.abort(new ConnectionClosedError('disconnect'))
  }

  /**
   * Create a View for a specific land
   */
  createView(landID: string, options?: ViewOptions): StateTreeView {
    // Check if a view with the same landType already exists
    // In multiroom mode, we might create view with "demo-game" but server returns "demo-game:instanceId"
    const landType = landID.split(':')[0]
    for (const [existingLandID, existingView] of this.views.entries()) {
      const existingLandType = existingLandID.split(':')[0]
      if (existingLandType === landType) {
        // Update the existing view's landID if it's just the landType
        if (existingLandID === landType && landID !== landType) {
          // Server returned a full landID, update the view
          this.views.delete(existingLandID)
          this.views.set(landID, existingView)
          ;(existingView as any).landID = landID
          this.logger.info(`Updated existing view landID: ${existingLandID} -> ${landID}`)
          return existingView
        } else if (existingLandID === landID) {
      throw new Error(`View for land ${landID} already exists`)
        }
      }
    }

    // No existing view found, create new one
    const view = new StateTreeView(this, landID, {
      schema: options?.schema,
      playerID: options?.playerID,
      deviceID: options?.deviceID,
      metadata: options?.metadata,
      logger: options?.logger,
      onStateUpdate: options?.onStateUpdate,
      onSnapshot: options?.onSnapshot,
      onTransportMessage: options?.onTransportMessage,
      onStateUpdateMessage: options?.onStateUpdateMessage,
      onSnapshotMessage: options?.onSnapshotMessage,
      onError: options?.onError,
      onPatch: options?.onPatch,
      onResync: options?.onResync
    })

    this.views.set(landID, view)
    return view
  }

  /** Destroys every view (rejecting its pending requests with `reason`) and clears the map. */
  private destroyAllViews(reason: ConnectionClosedError): void {
    const views = [...this.views.values()]
    this.views.clear()
    for (const view of views) view.destroy(reason)
  }

  /**
   * Remove a View
   */
  removeView(landID: string): void {
    const view = this.views.get(landID)
    if (view) {
      // Remove from map first to prevent infinite recursion
      this.views.delete(landID)
      // Then destroy the view (which won't call removeView again)
      view.destroy()
      // Its land's acks stop with it: the server drops acks from a session that left.
      if (this.views.size === 0) this.stopAcks()
    }
  }

  /**
   * Send a raw message through the WebSocket
   * @param message - The TransportMessage to send
   * @param encoding - Optional encoding format. If not provided, uses JSON (for join messages)
   */
  sendRawMessage(message: TransportMessage, encoding?: MessageEncoding): void {
    if (!this.ws) {
      throw new Error('WebSocket not connected')
    }

    // Join messages always use JSON format
    const useEncoding = encoding || MessageEncodingValues.json
    
    // Use unified encoding function
    const encoded = encodeMessageToFormat(message, useEncoding)
    let messageSize: number
    
    if (useEncoding === MessageEncodingValues.messagepack) {
      // MessagePack returns Uint8Array
      const msgpackData = encoded as Uint8Array
      messageSize = msgpackData.byteLength
      // Ensure WebSocket binaryType is set to 'arraybuffer' for binary messages
      // Convert Uint8Array to ArrayBuffer for WebSocket.send()
      // Use slice() to ensure we get an ArrayBuffer (not SharedArrayBuffer)
      const buffer = msgpackData.buffer instanceof ArrayBuffer 
        ? msgpackData.buffer.slice(msgpackData.byteOffset, msgpackData.byteOffset + msgpackData.byteLength)
        : new Uint8Array(msgpackData).buffer
      this.ws.send(buffer)
    } else {
      // JSON and opcodeJsonArray return string
      const jsonString = encoded as string
      messageSize = new TextEncoder().encode(jsonString).length
      this.ws.send(jsonString)
    }
    
    // Report outbound statistics
    if (this.statisticsCallback) {
      this.statisticsCallback({
        messageType: 'transportMessage',
        messageSize,
        direction: 'outbound'
      })
    }
  }

  /**
   * Check if runtime is connected
   */
  get connected(): boolean {
    return this.isConnected
  }

  /**
   * Handle incoming WebSocket message
   * Routes messages to appropriate View based on landID
   */
  private async handleMessage(data: unknown): Promise<void> {
    try {
      let text: string
      let messageSize: number

      // Calculate actual message size (bytes) before decoding
      let decoded: TransportMessage | StateUpdate | StateSnapshot | StateUpdateWithEvents
      
      if (typeof data === 'string') {
        // UTF-8 encoding: each character is 1-4 bytes, but for ASCII it's 1 byte
        // Use TextEncoder to get accurate byte length
        messageSize = new TextEncoder().encode(data).length
        decoded = decodeMessage(data, this.transportEncoding, {
          broadcast: this.broadcastDynamicKeyMap,
          perPlayer: this.perPlayerDynamicKeyMap
        })
      } else if (data instanceof ArrayBuffer) {
        messageSize = data.byteLength
        // MessagePack binary data - decode directly
        decoded = decodeMessage(data, this.transportEncoding, {
          broadcast: this.broadcastDynamicKeyMap,
          perPlayer: this.perPlayerDynamicKeyMap
        })
      } else if (ArrayBuffer.isView(data)) {
        messageSize = data.byteLength
        // MessagePack binary data - decode directly
        // Convert ArrayBufferView to Uint8Array for decodeMessage
        const uint8Array = new Uint8Array(data.buffer, data.byteOffset, data.byteLength)
        decoded = decodeMessage(uint8Array, this.transportEncoding, {
          broadcast: this.broadcastDynamicKeyMap,
          perPlayer: this.perPlayerDynamicKeyMap
        })
      } else if (typeof Blob !== 'undefined' && data instanceof Blob) {
        messageSize = data.size
        const arrayBuffer = await data.arrayBuffer()
        // MessagePack binary data - decode directly
        decoded = decodeMessage(arrayBuffer, this.transportEncoding, {
          broadcast: this.broadcastDynamicKeyMap,
          perPlayer: this.perPlayerDynamicKeyMap
        })
      } else {
        // Fallback: try to convert to string
        // This handles unexpected types as best effort
        const typeName = (data as any)?.constructor?.name ?? typeof data
        this.logger.warn(`Unexpected data type: ${typeName}, attempting to convert to string`)
        const text = String(data)
        messageSize = new TextEncoder().encode(text).length
        decoded = decodeMessage(text, this.transportEncoding, {
          broadcast: this.broadcastDynamicKeyMap,
          perPlayer: this.perPlayerDynamicKeyMap
        })
      }

      // Debug: log raw message structure
      this.logger.debug(`Received message: keys=${Object.keys(decoded).join(',')}, preview=${JSON.stringify(decoded).substring(0, 200)}`)

      // Route TransportMessage to appropriate View
      if ('kind' in decoded) {
        const message = decoded as TransportMessage
        this.logger.debug(`Routing as TransportMessage: kind=${message.kind}`)
        
        // Report inbound statistics
        if (this.statisticsCallback) {
          this.statisticsCallback({
            messageType: 'transportMessage',
            messageSize,
            direction: 'inbound'
          })
        }
        
        this.routeTransportMessage(message)
        return
      }

      // Opcode 107: state update with events merged — dispatch events first, then apply state
      // So notification events (e.g. "attack hit") are processed before state (e.g. monster dead),
      // giving cause-then-effect ordering: show attack feedback, then apply outcome.
      if ((decoded as StateUpdateWithEvents).type === 'stateUpdateWithEvents' && 'stateUpdate' in decoded && 'events' in decoded) {
        const combined = decoded as StateUpdateWithEvents
        this.logger.info(`📥 Received StateUpdateWithEvents: patches=${combined.stateUpdate.patches.length}, events=${combined.events.length}`)
        if (this.statisticsCallback) {
          this.statisticsCallback({
            messageType: 'stateUpdate',
            messageSize,
            direction: 'inbound',
            patchCount: combined.stateUpdate.patches.length
          })
        }
        for (const event of combined.events) {
          this.routeTransportMessage(event)
        }
        if (!this.coveredByResync(combined.stateUpdate)) {
          for (const view of this.views.values()) {
            view.handleStateUpdate(combined.stateUpdate)
          }
        }
        this.noteApplied(combined.stateUpdate)
        return
      }

      // Route StateUpdate to appropriate View
      if ('type' in decoded && 'patches' in decoded) {
        const update = decoded as StateUpdate
        this.logger.info(`📥 Received StateUpdate: type=${update.type}, patches=${update.patches.length}`)
        
        // Report inbound statistics
        if (this.statisticsCallback) {
          this.statisticsCallback({
            messageType: 'stateUpdate',
            messageSize,
            direction: 'inbound',
            patchCount: update.patches.length
          })
        }
        
        // StateUpdate doesn't have landID, so we need to route to all views
        // or find a way to determine which view it belongs to
        // For now, route to all views (they will ignore if not relevant)
        if (!this.coveredByResync(update)) {
          for (const view of this.views.values()) {
            view.handleStateUpdate(update)
          }
        }
        this.noteApplied(update)
        return
      }

      // Route StateSnapshot to appropriate View
      if ('values' in decoded) {
        const snapshot = decoded as StateSnapshot
        this.logger.info(`📥 Received StateSnapshot: fields=${Object.keys(snapshot.values).length}`)
        
        // Report inbound statistics
        if (this.statisticsCallback) {
          this.statisticsCallback({
            messageType: 'stateSnapshot',
            messageSize,
            direction: 'inbound'
          })
        }
        
        // StateSnapshot doesn't have landID, route to all views
        for (const view of this.views.values()) {
          view.handleSnapshot(snapshot)
        }
        return
      }

      this.logger.warn(`Unknown message format: ${JSON.stringify(decoded).substring(0, 100)}`)
    } catch (error) {
      this.logger.error(`Failed to parse message: ${error}`)
      this.noteDecodeError(error)
    }
  }

  /**
   * Messages that failed to decode (for example `Dynamic key slot N used before definition`).
   * `beforeLeave` counts errors before `disconnect()`; `afterLeave` counts errors after it, when
   * frames received before it are decoded against cleared key maps (#190). Frames that arrive
   * on the dropped socket afterwards are ignored, not decoded (#143).
   */
  decodeErrorStats(): DecodeErrorStats {
    return { ...this.decodeErrors, samples: [...this.decodeErrors.samples] }
  }

  private noteDecodeError(error: unknown): void {
    if (this.leaving) {
      this.decodeErrors.afterLeave += 1
    } else {
      this.decodeErrors.beforeLeave += 1
    }
    if (this.decodeErrors.samples.length < DECODE_ERROR_SAMPLE_LIMIT) {
      this.decodeErrors.samples.push(`${this.leaving ? 'after leave' : 'before leave'}: ${String(error)}`)
    }
  }

  /**
   * Route TransportMessage to appropriate View
   */
  private routeTransportMessage(message: TransportMessage): void {
    // Extract landID from message payload
    let landID: string | undefined

    const payload = message.payload as any

    // Try to extract landID from different message types
    // landID removed from action and event payloads - server identifies land from session mapping
    if (payload.join?.landID) {
      landID = payload.join.landID
    } else if (payload.joinResponse?.landID) {
      landID = payload.joinResponse.landID
    } else if (message.kind === 'error') {
      // For error messages, try to extract landID from error details
      const errorPayload = payload.error || payload
      const details = errorPayload.details || {}
      landID = details.landID
    }

    if (landID) {
      let view = this.views.get(landID)
      
      // If exact match not found, try to match by landType (for multiroom mode)
      // e.g., if landID is "demo-game:abc123" and we have view for "demo-game"
      if (!view && this.views.size > 0) {
        const landType = landID.split(':')[0]
        for (const [viewLandID, candidateView] of this.views.entries()) {
          const viewLandType = viewLandID.split(':')[0]
          if (viewLandType === landType) {
            view = candidateView
            // Update view's internal landID to match server's actual landID
            if (view && (view as any).landID !== landID) {
              (view as any).landID = landID
              // Update the views map to use the new landID as key
              this.views.delete(viewLandID)
              this.views.set(landID, view)
              this.logger.info(`Updated view landID mapping: ${viewLandID} -> ${landID}`)
            }
            break
          }
        }
      }
      
      if (view) {
        view.handleTransportMessage(message)
      } else {
        // Fallback: route to all views if no exact or landType match found
        // This ensures messages are not lost and CLI doesn't hang
        if (this.views.size > 0) {
          // Only log as debug to avoid noise, but always route to prevent message loss
          this.logger.debug(`No exact view match for landID: ${landID}, routing to all views (${this.views.size}) as fallback`)
          for (const view of this.views.values()) {
            view.handleTransportMessage(message)
          }
        } else {
          this.logger.warn(`No view found for landID: ${landID} (no views available)`)
        }
      }
    } else {
      // No landID in message, try to route to all views or handle globally
      // For error messages, always route to all views so they can handle errors
      // even if requestID extraction fails
      if (message.kind === 'error') {
        const errorPayload = message.payload as any
        // Always route error messages to all views
        // This ensures errors are properly handled even if requestID extraction fails
        if (this.views.size > 0) {
          for (const view of this.views.values()) {
            view.handleTransportMessage(message)
          }
        } else {
          // Log as global error only if no views exist (for debugging)
          // This can happen if error occurs before view is created
          this.logger.error(`Global error (no views): ${JSON.stringify(errorPayload)}`)
          
          // Try to extract requestID and see if we can match it to a pending action
          // This is a fallback for errors that occur before view creation
          const nestedError = errorPayload.error || errorPayload
          const details = nestedError.details || {}
          const requestID = details.requestID
          if (requestID) {
            this.logger.warn(`Error has requestID but no views exist: ${requestID}`)
          }
        }
      } else {
        // Unknown message without landID, route to all views
        for (const view of this.views.values()) {
          view.handleTransportMessage(message)
        }
      }
    }
  }
}

function resolveRuntimeOptions(options?: Logger | RuntimeOptions): { logger: Logger; transportEncoding: TransportEncodingConfig } {
  const defaultConfig: TransportEncodingConfig = {
    message: MessageEncodingValues.json,
    stateUpdate: StateUpdateEncodingValues.opcodeJsonArray,
    stateUpdateDecoding: 'auto'
  }

  if (!options) {
    return { logger: new NoOpLogger(), transportEncoding: defaultConfig }
  }

  if (isLogger(options)) {
    return { logger: options, transportEncoding: defaultConfig }
  }

  const logger = options.logger ?? new NoOpLogger()
  const transportEncoding: TransportEncodingConfig = {
    message: options.transportEncoding?.message ?? MessageEncodingValues.json,
    stateUpdate: options.transportEncoding?.stateUpdate ?? StateUpdateEncodingValues.opcodeJsonArray,
    stateUpdateDecoding: options.transportEncoding?.stateUpdateDecoding ?? 'auto'
  }

  return { logger, transportEncoding }
}

function isLogger(value: Logger | RuntimeOptions): value is Logger {
  const candidate = value as Logger
  return typeof candidate.info === 'function' && typeof candidate.error === 'function'
}
