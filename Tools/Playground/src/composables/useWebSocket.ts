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

  // Track current landID (may be updated after join if server returns different one)
  const currentLandID = ref<string>(LAND_ID)
  const currentPlayerID = ref<string | null>(null)

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
        },
        onStateUpdateMessage: (update) => {
          // The SDK already applied patches and invoked onStateUpdate.
          // We only use this callback to record update metadata for the UI.
          handleStateUpdate(update as StateUpdate)
        },
        onTransportMessage: (message) => {
          addLog(`Transport message [${message.kind}]`, 'server', message)
        },
        onError: (error) => {
          addLog(
            `SDK error: ${error instanceof Error ? error.message : String(error)}`,
            'error',
            error
          )
        }
      })

      // Subscribe to all server events (we'll need to handle this differently)
      // For now, events are logged by View's logger

      // Join automatically
      try {
        const joinResult = await view.join()
        if (joinResult.success) {
          isJoined.value = true
          
          // Update current landID from join result or view's current landID
          // The view automatically updates its landID if server returns a different one
          const actualLandID = joinResult.landID || view.getCurrentLandID() || currentLandID.value
          if (actualLandID !== currentLandID.value) {
            currentLandID.value = actualLandID
            if (actualLandID !== LAND_ID) {
              addLog(`ℹ️  LandID 已更新: ${LAND_ID} -> ${actualLandID}`, 'info')
            }
          }
          
          // Update current playerID
          if (joinResult.playerID) {
            currentPlayerID.value = joinResult.playerID
          }
          
          addLog(`✅ Join 成功: playerID=${joinResult.playerID || 'unknown'}, landID=${actualLandID}`, 'success')
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
    currentLandID.value = LAND_ID  // Reset to initial value
    currentPlayerID.value = null
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
    currentLandID,
    currentPlayerID,
    logs,
    stateUpdates,
    actionResults,
    connect,
    disconnect,
    sendAction,
    sendEvent
  }
}
