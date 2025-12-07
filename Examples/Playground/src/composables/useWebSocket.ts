import { ref, Ref } from 'vue'
import type { Schema, TransportMessage } from '@/types'
import type { LogEntry, StateUpdate, StatePatch } from '@/types/transport'

export interface StateUpdateEntry {
  id: string
  timestamp: Date
  type: 'snapshot' | 'firstSync' | 'diff' | 'noChange'
  patchCount?: number
  message: string
  patches?: StatePatch[]  // 保存完整的 patches
  affectedPaths?: string[]  // 受影響的路徑列表（用於合併和過濾）
}

export function useWebSocket(wsUrl: Ref<string>, schema: Ref<Schema | null>) {
  const ws = ref<WebSocket | null>(null)
  const isConnected = ref(false)
  const isJoined = ref(false)
  const currentState = ref<Record<string, any>>({})
  const logs = ref<LogEntry[]>([])
  
  // Separate state update log (not mixed with general logs)
  const stateUpdates = ref<StateUpdateEntry[]>([])

  const decodeSnapshotValue = (value: any): any => {
    if (value === null || value === undefined) return null
    if (typeof value !== 'object') return value

    const unwrap = (v: any): any => {
      if (v && typeof v === 'object' && '_0' in v) {
        return (v as any)._0
      }
      return v
    }

    if ('null' in value) return null
    if ('bool' in value) return unwrap(value.bool)
    if ('int' in value) return unwrap(value.int)
    if ('double' in value) return unwrap(value.double)
    if ('string' in value) return unwrap(value.string)

    if ('array' in value) {
      const arrayValue = unwrap(value.array)
      if (Array.isArray(arrayValue)) {
        return arrayValue.map((item: any) => decodeSnapshotValue(item))
      }
    }

    if ('object' in value) {
      const objectValue = unwrap(value.object)
      if (objectValue && typeof objectValue === 'object') {
        const result: Record<string, any> = {}
        for (const [key, val] of Object.entries(objectValue as Record<string, any>)) {
          result[key] = decodeSnapshotValue(val)
        }
        return result
      }
    }

    // Fallback for plain object/dictionary structures
    if (value && typeof value === 'object') {
      const result: Record<string, any> = {}
      for (const [key, val] of Object.entries(value as Record<string, any>)) {
        result[key] = decodeSnapshotValue(val)
      }
      return result
    }

    return value
  }

  // Apply JSON Patch (RFC 6902) to state
  const applyPatch = (state: Record<string, any>, patch: StatePatch): void => {
    const path = patch.path
    if (!path.startsWith('/')) {
      addLog(`❌ 無效的 patch path: ${path}`, 'error')
      return
    }

    const parts = path.split('/').filter(p => p !== '')
    if (parts.length === 0) {
      addLog(`❌ 空的 patch path: ${path}`, 'error')
      return
    }

    const key = parts[0]
    const restPath = '/' + parts.slice(1).join('/')

    if (parts.length === 1) {
      // Top-level property
      switch (patch.op) {
        case 'replace':
        case 'add':
          state[key] = decodeSnapshotValue(patch.value)
          break
        case 'remove':
          delete state[key]
          break
      }
    } else {
      // Nested property
      if (!(key in state) || typeof state[key] !== 'object' || state[key] === null) {
        state[key] = {}
      }
      applyPatch(state[key], { ...patch, path: restPath })
    }
  }

  // Apply multiple patches to state
  const applyPatches = (state: Record<string, any>, patches: StatePatch[]): void => {
    for (const patch of patches) {
      applyPatch(state, patch)
    }
  }

  const addLog = (message: string, type: LogEntry['type'] = 'info', data?: any) => {
    logs.value.push({
      id: Date.now().toString() + Math.random().toString(36).substr(2, 9),
      timestamp: new Date(),
      type,
      message,
      data
    })
    // Keep only last 1000 logs
    if (logs.value.length > 1000) {
      logs.value.shift()
    }
  }

  const connect = (): void => {
    if (ws.value?.readyState === WebSocket.OPEN) {
      addLog('已經連線', 'warning')
      return
    }

    try {
      addLog(`正在連線到 ${wsUrl.value}...`, 'info')
      ws.value = new WebSocket(wsUrl.value)
      // We expect the server to send binary frames containing JSON.
      ws.value.binaryType = 'blob'

      ws.value.onopen = () => {
        isConnected.value = true
        isJoined.value = false
        addLog('✅ WebSocket 連線成功', 'success')
        
        // Automatically send join request after connection
        const requestID = `join-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`
        const joinMessage: TransportMessage = {
          join: {
            requestID,
            landID: 'demo-game', // Match the landID from DemoDefinitions.swift
            playerID: undefined,
            deviceID: undefined,
            metadata: undefined
          }
        }
        
        try {
          const json = JSON.stringify(joinMessage)
          ws.value.send(json)
          addLog('📤 發送 join 請求', 'info')
        } catch (err) {
          addLog(`❌ 發送 join 請求失敗: ${err}`, 'error')
        }
      }

      ws.value.onerror = (error) => {
        addLog(`❌ WebSocket 錯誤: ${error}`, 'error')
      }

      ws.value.onclose = (event) => {
        isConnected.value = false
        isJoined.value = false
        if (event.code !== 1000) {
          addLog(`🔌 連線關閉 (代碼: ${event.code}, 原因: ${event.reason || '無'})`, 'warning')
        } else {
          addLog('🔌 WebSocket 連線已關閉', 'info')
        }
      }

      ws.value.onmessage = (event) => {
        const raw = event.data

          const handleJsonText = (text: string) => {
            try {
              const data = JSON.parse(text) as TransportMessage | StateUpdate | any

              // Check for joinResponse
              if (data && typeof data === 'object' && 'joinResponse' in data) {
                const joinResponse = (data as any).joinResponse
                if (joinResponse.success) {
                  isJoined.value = true
                  addLog(`✅ Join 成功: playerID=${joinResponse.playerID || 'unknown'}`, 'success')
                } else {
                  isJoined.value = false
                  addLog(`❌ Join 失敗: ${joinResponse.reason || '未知原因'}`, 'error')
                }
                return // Don't process further
              }
              
              // Check for StateSnapshot format (initial connection - complete snapshot)
              if (data && typeof data === 'object' && 'values' in data && data.values && typeof data.values === 'object') {
              // Initial snapshot format (complete state from lateJoinSnapshot)
              // Merge into existing state to preserve UI state (like expanded folders)
              const decodedState: Record<string, any> = {}
              for (const [key, value] of Object.entries(data.values as Record<string, any>)) {
                decodedState[key] = decodeSnapshotValue(value)
              }
              
              // Deep merge to preserve existing state structure and avoid full re-render
              if (currentState.value && Object.keys(currentState.value).length > 0) {
                // Merge new values into existing state
                Object.assign(currentState.value, decodedState)
              } else {
                // First time, just assign
                currentState.value = decodedState
              }
              
              // Add to state updates (separate from general logs)
              stateUpdates.value.push({
                id: Date.now().toString() + Math.random().toString(36).substr(2, 9),
                timestamp: new Date(),
                type: 'snapshot',
                message: '初始狀態已接收 (完整快照)'
              })
              
              // Keep only last 100 state updates
              if (stateUpdates.value.length > 100) {
                stateUpdates.value.shift()
              }
              return // Don't process further
            }
            
            // Check for StateUpdate format (new diff/patch format)
            if (data && typeof data === 'object' && 'type' in data && ('firstSync' === data.type || 'diff' === data.type || 'noChange' === data.type)) {
              const update = data as StateUpdate
              
              if (update.type === 'noChange') {
                // Don't log noChange to reduce noise
                return
              }

              const patches = update.patches || []
              
              // 提取受影響的路徑（頂層 key）
              const affectedPaths = Array.from(new Set(
                patches.map(patch => {
                  const pathParts = patch.path.split('/').filter(part => part !== '')
                  return pathParts.length > 0 ? pathParts[0] : patch.path
                })
              ))
              
              if (update.type === 'firstSync') {
                // First sync: initialize state from patches (if state is empty)
                if (!currentState.value || Object.keys(currentState.value).length === 0) {
                  currentState.value = {}
                }
                applyPatches(currentState.value, patches)
              } else if (update.type === 'diff') {
                // Diff: apply patches to existing state
                if (!currentState.value || Object.keys(currentState.value).length === 0) {
                  // If state is empty, treat as first sync
                  currentState.value = {}
                }
                applyPatches(currentState.value, patches)
              }
              
              // Add to state updates (separate from general logs)
              stateUpdates.value.push({
                id: Date.now().toString() + Math.random().toString(36).substr(2, 9),
                timestamp: new Date(),
                type: update.type,
                patchCount: patches.length,
                message: update.type === 'firstSync' 
                  ? `首次同步完成 (${patches.length} 個 patches)`
                  : `狀態已更新 (${patches.length} 個 patches)`,
                patches: patches,  // 保存完整的 patches
                affectedPaths: affectedPaths  // 保存受影響的路徑
              })
              
              // Keep only last 100 state updates
              if (stateUpdates.value.length > 100) {
                stateUpdates.value.shift()
              }
            } else {
              // Other messages (events, actions) go to general logs
              if (data.event?.event?.fromServer) {
                // Server event: only log the event content, not the full message structure
                const eventData = data.event.event.fromServer
                addLog(`📨 伺服器事件: ${JSON.stringify(eventData)}`, 'server')
              } else if (data.actionResponse) {
                addLog(`✅ Action 回應: ${JSON.stringify(data.actionResponse.response)}`, 'success')
              } else {
                // For other message types, log the full message
                addLog('📥 收到訊息', 'server', data)
              }
            }
          } catch (err) {
            addLog(`❌ 解析訊息失敗: ${err}`, 'error', text)
          }
        }

        if (typeof raw === 'string') {
          handleJsonText(raw)
        } else if (raw instanceof Blob) {
          raw.text()
            .then(handleJsonText)
            .catch((err) => {
              addLog(`❌ 讀取訊息資料失敗: ${err}`, 'error')
            })
        } else if (raw instanceof ArrayBuffer) {
          const text = new TextDecoder('utf-8').decode(new Uint8Array(raw))
          handleJsonText(text)
        } else {
          // Fallback: try to stringify unknown data
          try {
            handleJsonText(String(raw))
          } catch {
            addLog('❌ 無法處理收到的資料', 'error', raw)
          }
        }
      }
    } catch (err) {
      addLog(`❌ 連線失敗: ${err}`, 'error')
    }
  }

  const disconnect = (): void => {
    if (ws.value) {
      ws.value.close(1000, 'User disconnect')
      ws.value = null
    }
  }

  const sendMessage = (message: TransportMessage): void => {
    if (!ws.value || ws.value.readyState !== WebSocket.OPEN) {
      addLog('請先連線到伺服器', 'warning')
      return
    }

    try {
      const json = JSON.stringify(message)
      ws.value.send(json)
      addLog(`📤 發送訊息`, 'info', message)
    } catch (err) {
      addLog(`❌ 發送失敗: ${err}`, 'error')
    }
  }

  const sendAction = (actionName: string, payload: any, landID: string): void => {
    const requestID = `req-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`
    
    // Encode payload as base64
    const payloadJson = JSON.stringify(payload)
    const payloadBase64 = btoa(unescape(encodeURIComponent(payloadJson)))

    const message: TransportMessage = {
      action: {
        requestID,
        landID,
        action: {
          typeIdentifier: actionName,
          payload: payloadBase64
        }
      }
    }

    sendMessage(message)
  }

  const sendEvent = (eventName: string, payload: any, landID: string): void => {
    // Get event type name from schema if available (for server events)
    // Note: Client events are not in schema, so we need to infer the type name
    let typeName: string | null = null
    if (schema.value) {
      const land = schema.value.lands[landID]
      if (land?.events?.[eventName]) {
        const ref = land.events[eventName].$ref
        if (ref) {
          // Extract type name from $ref like "#/defs/ChatMessageEvent"
          const match = ref.match(/#\/defs\/(.+)$/)
          if (match) {
            typeName = match[1]
          }
        }
      }
    }
    
    // For client events, convert event name to type name
    // Common patterns:
    // - "chat" -> "ChatEvent"
    // - "ping" -> "PingEvent"
    // - "chatmessage" -> "ChatMessageEvent" (camelCase to PascalCase)
    if (!typeName) {
      // Convert camelCase/kebab-case to PascalCase
      const parts = eventName.split(/[-_]/)
      const pascalParts = parts.map(part => 
        part.charAt(0).toUpperCase() + part.slice(1)
      )
      typeName = pascalParts.join('') + 'Event'
    }
    
    // Create AnyClientEvent structure: { type: string, payload: AnyCodable }
    // Note: rawBody is optional and can be omitted
    const anyClientEvent = {
      type: typeName,
      payload: payload || {}
    }
    
    // Swift enum with associated values uses _0, _1, etc. as keys in Codable
    // TransportEvent.fromClient(AnyClientEvent) encodes as { "fromClient": { "_0": AnyClientEvent } }
    const message: TransportMessage = {
      event: {
        landID,
        event: {
          fromClient: {
            _0: anyClientEvent
          }
        }
      }
    }

    sendMessage(message)
  }

  return {
    isConnected,
    isJoined,
    currentState,
    logs,
    stateUpdates,
    connect,
    disconnect,
    sendAction,
    sendEvent
  }
}
