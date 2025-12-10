import { ref, Ref, watch } from 'vue'
import type { Schema } from '@/types'
import type { LogEntry, StatePatch, StateUpdate } from '@/types/transport'
import { StateTreeRuntime, StateTreeView } from '@swiftstatetree/sdk/core'
import { createPlaygroundLogger } from './playgroundLogger.js'

export interface StateUpdateEntry {
  id: string
  timestamp: Date
  type: 'snapshot' | 'firstSync' | 'diff' | 'noChange'
  patchCount?: number
  message: string
  patches?: StatePatch[]
  affectedPaths?: string[]
}

const LAND_ID = 'demo-game' // Match the landID from DemoDefinitions.swift

export function useWebSocket(wsUrl: Ref<string>, schema: Ref<Schema | null>) {
  const isConnected = ref(false)
  const isJoined = ref(false)
  const connectionError = ref<string | null>(null)
  const currentState = ref<Record<string, any>>({})
  const logs = ref<LogEntry[]>([])
  const stateUpdates = ref<StateUpdateEntry[]>([])
  const actionResults = ref<Array<{
    actionName: string
    success: boolean
    response?: any
    error?: string
    timestamp: Date
  }>>([])

  // Track action requests to match responses
  const actionRequestMap = ref<Map<string, { actionName: string, timestamp: Date }>>(new Map())

  // SDK instances
  let runtime: StateTreeRuntime | null = null
  let view: StateTreeView | null = null

  const logger = createPlaygroundLogger(logs)
  
  // Debug: verify logger is created
  console.log('[Playground] Logger created:', typeof logger.info === 'function')

  const addLog = (message: string, type: LogEntry['type'] = 'info', data?: any) => {
    logs.value.push({
      id: Date.now().toString() + Math.random().toString(36).substr(2, 9),
      timestamp: new Date(),
      type,
      message,
      data
    })
    if (logs.value.length > 1000) {
      logs.value.shift()
    }
  }

  // Helper to extract affected paths from patches
  const extractAffectedPaths = (patches: StatePatch[]): string[] => {
    return Array.from(new Set(
      patches.map(patch => {
        const pathParts = patch.path.split('/').filter(part => part !== '')
        return pathParts.length > 0 ? pathParts[0] : patch.path
      })
    ))
  }

  // Handle state updates from View
  const handleStateUpdate = (update: StateUpdate) => {
    if (update.type === 'noChange') {
      return
    }

    const patches = update.patches || []
    const affectedPaths = extractAffectedPaths(patches)

    if (update.type === 'firstSync') {
      if (!currentState.value || Object.keys(currentState.value).length === 0) {
        currentState.value = {}
      }
      // Apply patches
      for (const patch of patches) {
        applyPatch(currentState.value, patch)
      }
    } else if (update.type === 'diff') {
      if (!currentState.value || Object.keys(currentState.value).length === 0) {
        currentState.value = {}
      }
      for (const patch of patches) {
        applyPatch(currentState.value, patch)
      }
    }

    // Add to state updates
    stateUpdates.value.push({
      id: Date.now().toString() + Math.random().toString(36).substr(2, 9),
      timestamp: new Date(),
      type: update.type,
      patchCount: patches.length,
      message: update.type === 'firstSync'
        ? `首次同步完成 (${patches.length} 個 patches)`
        : `狀態已更新 (${patches.length} 個 patches)`,
      patches: patches,
      affectedPaths: affectedPaths
    })

    // Keep only last 3 updates per top-level path and cap total at 100
    const byPath: Record<string, StateUpdateEntry[]> = {}
    for (const entry of [...stateUpdates.value].reverse()) {
      const paths = entry.patches?.map(p => {
        const parts = p.path.split('/').filter(Boolean)
        return parts[0] || '/'
      }) ?? entry.affectedPaths ?? ['/']

      const uniquePaths = Array.from(new Set(paths))
      for (const path of uniquePaths) {
        byPath[path] = byPath[path] ?? []
        if (byPath[path].length < 3) {
          byPath[path].push(entry)
        }
      }
    }
    const merged = Object.values(byPath).flat()
    merged.sort((a, b) => b.timestamp.getTime() - a.timestamp.getTime())
    stateUpdates.value = merged.slice(0, 100)
  }

  // Handle snapshot from View
  const handleSnapshot = (snapshot: { values: Record<string, any> }) => {
    const decodedState: Record<string, any> = {}
    for (const [key, value] of Object.entries(snapshot.values)) {
      decodedState[key] = decodeSnapshotValue(value)
    }

    if (currentState.value && Object.keys(currentState.value).length > 0) {
      Object.assign(currentState.value, decodedState)
    } else {
      currentState.value = decodedState
    }

    stateUpdates.value.push({
      id: Date.now().toString() + Math.random().toString(36).substr(2, 9),
      timestamp: new Date(),
      type: 'snapshot',
      message: '初始狀態已接收 (完整快照)'
    })

    if (stateUpdates.value.length > 100) {
      stateUpdates.value.shift()
    }
  }

  // Decode SnapshotValue
  const decodeSnapshotValue = (value: any): any => {
    if (value === null || value === undefined) return null
    if (typeof value !== 'object') return value

    if ('type' in value) {
      const type = value.type
      if (type === 'null') return null
      if (!('value' in value)) {
        throw new Error(`Invalid SnapshotValue: type "${type}" requires "value" field`)
      }
      const val = value.value

      switch (type) {
        case 'bool':
        case 'int':
        case 'double':
        case 'string':
          return val
        case 'array':
          if (Array.isArray(val)) {
            return val.map((item: any) => decodeSnapshotValue(item))
          }
          throw new Error(`Invalid SnapshotValue array: expected array, got ${typeof val}`)
        case 'object':
          if (val && typeof val === 'object') {
            const result: Record<string, any> = {}
            for (const [key, v] of Object.entries(val as Record<string, any>)) {
              result[key] = decodeSnapshotValue(v)
            }
            return result
          }
          throw new Error(`Invalid SnapshotValue object: expected object, got ${typeof val}`)
        default:
          throw new Error(`Unknown SnapshotValue type: ${type}`)
      }
    }

    throw new Error(`Invalid SnapshotValue format: ${JSON.stringify(value)}`)
  }

  // Apply patch to state
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
      if (!(key in state) || typeof state[key] !== 'object' || state[key] === null) {
        state[key] = {}
      }
      applyPatch(state[key], { ...patch, path: restPath })
    }
  }

  const connect = async (customUrl?: string): Promise<void> => {
    if (runtime?.connected) {
      addLog('已經連線', 'warning')
      return
    }

    connectionError.value = null

    try {
      const urlToUse = customUrl ?? wsUrl.value
      addLog(`正在連線到 ${urlToUse}...`, 'info')

      // Create runtime and view
      console.log('[Playground] Creating runtime with logger:', logger)
      runtime = new StateTreeRuntime(logger)
      console.log('[Playground] Runtime created, connecting...')
      await runtime.connect(urlToUse)
      console.log('[Playground] Connection completed')

      isConnected.value = true
      isJoined.value = false
      connectionError.value = null
      addLog('✅ WebSocket 連線成功', 'success')

      // Create view with state update callbacks
      view = runtime.createView(LAND_ID, {
        logger,
        onStateUpdate: (state) => {
          currentState.value = state
        },
        onSnapshot: (snapshot) => {
          handleSnapshot(snapshot)
        }
      })

      // Subscribe to all server events (we'll need to handle this differently)
      // For now, events are logged by View's logger

      // Join automatically
      try {
        const joinResult = await view.join()
        if (joinResult.success) {
          isJoined.value = true
          addLog(`✅ Join 成功: playerID=${joinResult.playerID || 'unknown'}`, 'success')
        } else {
          isJoined.value = false
          addLog(`❌ Join 失敗: ${joinResult.reason || '未知原因'}`, 'error')
        }
      } catch (err) {
        addLog(`❌ Join 失敗: ${err}`, 'error')
      }

      // Note: Server events are handled through View's event handlers
      // We'll need to subscribe to specific event types or handle them in View

    } catch (err) {
      const errorMessage = `連線失敗: ${err instanceof Error ? err.message : String(err)}`
      connectionError.value = errorMessage
      addLog(`❌ ${errorMessage}`, 'error')
      isConnected.value = false
    }
  }

  const disconnect = (): void => {
    if (runtime) {
      runtime.disconnect()
      runtime = null
      view = null
    }
    isConnected.value = false
    isJoined.value = false
    currentState.value = {}
    logs.value = []
    stateUpdates.value = []
  }

  const sendAction = (actionName: string, payload: any, landID: string = LAND_ID, requestID?: string): void => {
    if (!view || !view.joined) {
      addLog('請先連線並加入 land', 'warning')
      return
    }

    const reqID = requestID || `req-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`
    
    // Track this action request
    actionRequestMap.value.set(reqID, {
      actionName,
      timestamp: new Date()
    })

    if (actionRequestMap.value.size > 100) {
      const firstKey = actionRequestMap.value.keys().next().value
      if (firstKey !== undefined) {
        actionRequestMap.value.delete(firstKey)
      }
    }

    // Send action and handle response
    view.sendAction(actionName, payload || {})
      .then((response) => {
        addLog(`✅ Action 回應 [${actionName}]: ${JSON.stringify(response)}`, 'success')
        actionResults.value.push({
          actionName,
          success: true,
          response,
          timestamp: new Date()
        })
        if (actionResults.value.length > 50) {
          actionResults.value.shift()
        }
      })
      .catch((error) => {
        addLog(`❌ Action [${actionName}] 失敗: ${error}`, 'error')
        actionResults.value.push({
          actionName,
          success: false,
          error: String(error),
          timestamp: new Date()
        })
        if (actionResults.value.length > 50) {
          actionResults.value.shift()
        }
      })
  }

  const sendEvent = (eventName: string, payload: any, landID: string = LAND_ID): void => {
    if (!view || !view.joined) {
      addLog('請先連線並加入 land', 'warning')
      return
    }

    view.sendEvent(eventName, payload || {})
    addLog(`📤 發送事件 [${eventName}]: ${JSON.stringify(payload)}`, 'info')
  }

  return {
    isConnected,
    isJoined,
    connectionError,
    currentState,
    logs,
    stateUpdates,
    actionResults,
    connect,
    disconnect,
    sendAction,
    sendEvent
  }
}
