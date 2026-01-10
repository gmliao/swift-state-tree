import { ref, Ref, watch } from 'vue'
import type { Schema } from '@/types'
import type { LogEntry, StatePatch, StateUpdate } from '@/types/transport'
import { StateTreeRuntime, StateTreeView } from '@swiftstatetree/sdk/core'
import { createPlaygroundLogger } from './playgroundLogger.js'

// MessageStatistics type (matches SDK's MessageStatistics interface)
type RawMessageStatistics = {
  messageType: 'stateUpdate' | 'stateSnapshot' | 'transportMessage'
  messageSize: number
  direction: 'inbound' | 'outbound'
  patchCount?: number
}

type MessageStatistics = RawMessageStatistics & {
  sequence: number
}

export interface StateUpdateEntry {
  id: string
  timestamp: Date
  type: 'snapshot' | 'firstSync' | 'diff' | 'noChange'
  patchCount?: number
  message: string
  patches?: StatePatch[]
  affectedPaths?: string[]
  // Debug information
  tickId?: number | null
  messageSize?: number
  direction?: 'inbound' | 'outbound'
  landID?: string
  playerID?: string
  sequenceNumber?: number
}

export function useWebSocket(
  wsUrl: Ref<string>, 
  schema: Ref<Schema | null>, 
  selectedLandID: Ref<string> = ref(''), 
  landInstanceId: Ref<string> = ref('default'),
  enableLogs: Ref<boolean> = ref(true)
) {
  const isConnected = ref(false)
  const isJoined = ref(false)
  const connectionError = ref<string | null>(null)
  const currentState = ref<Record<string, any>>({})
  const logs = ref<LogEntry[]>([])
  const stateUpdates = ref<StateUpdateEntry[]>([])
  const messageStatistics = ref<MessageStatistics[]>([]) // Raw statistics from SDK
  const actionResults = ref<Array<{
    actionName: string
    success: boolean
    response?: any
    error?: string
    timestamp: Date
  }>>([])

  // Build full landID from landType and landInstanceId
  // Format: "landType:instanceId" or just "landType" if instanceId is empty/null
  // If instanceId is "default", it will be included in the landID to join the "default" room
  const buildLandID = (landType: string, instanceId: string | null | undefined): string => {
    if (!landType) {
      // Fallback: use first land from schema if available
      if (schema.value && schema.value.lands) {
        const landKeys = Object.keys(schema.value.lands)
        if (landKeys.length > 0) {
          landType = landKeys[0]
        }
      }
      if (!landType) {
        return 'demo-game'
      }
    }
    
    // If instanceId is provided and not empty (including "default"), format as "landType:instanceId"
    // Empty string or null means single-room mode (no instance ID)
    if (instanceId && instanceId.trim() !== '') {
      return `${landType}:${instanceId.trim()}`
    }
    
    // Otherwise, just return landType (single-room mode, server will create/assign a room)
    return landType
  }

  // Get initial landID from selectedLandID and landInstanceId
  const getInitialLandID = (): string => {
    return buildLandID(selectedLandID.value, landInstanceId.value)
  }
  
  // Track current landID (may be updated after join if server returns different one)
  const currentLandID = ref<string>(getInitialLandID())
  const currentPlayerID = ref<string | null>(null)
  
  // Track action requests to match responses
  const actionRequestMap = ref<Map<string, { actionName: string, timestamp: Date }>>(new Map())

  // SDK instances
  let runtime: StateTreeRuntime | null = null
  let view: StateTreeView | null = null

  const logger = createPlaygroundLogger(logs, enableLogs)
  
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
  
  // Update currentLandID when selectedLandID or landInstanceId changes
  // Avoid desync: don't update currentLandID if already connected/joined
  // The view is bound to the landID used during connect, so changing it
  // without recreating the view would cause actions/events to target the wrong land
  watch([selectedLandID, landInstanceId], ([newLandID, newInstanceId]) => {
    // If connected/joined, don't update currentLandID to avoid desync
    // User should disconnect first before changing land selection
    if (isConnected.value || isJoined.value) {
      addLog(
        `⚠️ 無法更改 Land 選擇：請先斷線後再選擇新的 Land (目前連接至: ${currentLandID.value})`,
        'warning'
      )
      return
    }
    
    currentLandID.value = buildLandID(newLandID || '', newInstanceId || '')
  })

  // Helper to extract affected paths from patches
  const extractAffectedPaths = (patches: StatePatch[]): string[] => {
    return Array.from(new Set(
      patches.map(patch => {
        const pathParts = patch.path.split('/').filter(part => part !== '')
        return pathParts.length > 0 ? pathParts[0] : patch.path
      })
    ))
  }

  // Sequence number for tracking update order
  let updateSequenceNumber = 0
  let statsSequenceNumber = 0

  // Handle state updates from View
  // Note: stateUpdates are always collected (needed for StatisticsPanel)
  const handleStateUpdate = (update: StateUpdate) => {
    if (update.type === 'noChange') {
      return
    }

    const patches = update.patches || []
    const affectedPaths = extractAffectedPaths(patches)
    
    // Try to extract tickId from current state (if available)
    let tickId: number | null = null
    try {
      if (currentState.value && typeof currentState.value === 'object') {
        // Check common tickId locations in state
        if ('tickId' in currentState.value && typeof currentState.value.tickId === 'number') {
          tickId = currentState.value.tickId
        } else if ('currentTick' in currentState.value && typeof currentState.value.currentTick === 'number') {
          tickId = currentState.value.currentTick
        }
      }
    } catch (e) {
      // Ignore errors when accessing state
    }
    
    // Find corresponding message statistics for this update
    let messageSize: number | undefined
    let direction: 'inbound' | 'outbound' | undefined
    if (messageStatistics.value.length > 0) {
      // Find the most recent stateUpdate statistics entry
      for (let i = messageStatistics.value.length - 1; i >= 0; i--) {
        const stat = messageStatistics.value[i]
        if (stat.messageType === 'stateUpdate' && stat.direction === 'inbound') {
          messageSize = stat.messageSize
          direction = stat.direction
          break
        }
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
      affectedPaths: affectedPaths,
      // Debug information
      tickId: tickId,
      messageSize: messageSize,
      direction: direction || 'inbound',
      landID: currentLandID.value,
      playerID: currentPlayerID.value || undefined,
      sequenceNumber: updateSequenceNumber++
    })

    // Keep only last 1000 updates, remove oldest if exceeded
    if (stateUpdates.value.length > 1000) {
      stateUpdates.value = stateUpdates.value.slice(-1000)
    }
  }

  // Handle snapshot from View
  // Note: stateUpdates are always collected (needed for StatisticsPanel)
  const handleSnapshot = (snapshot: { values: Record<string, any> }) => {
    // Try to extract tickId from snapshot
    let tickId: number | null = null
    try {
      if (snapshot.values && typeof snapshot.values === 'object') {
        if ('tickId' in snapshot.values && typeof snapshot.values.tickId === 'number') {
          tickId = snapshot.values.tickId
        } else if ('currentTick' in snapshot.values && typeof snapshot.values.currentTick === 'number') {
          tickId = snapshot.values.currentTick
        }
      }
    } catch (e) {
      // Ignore errors
    }
    
    // Find corresponding message statistics for this snapshot
    let messageSize: number | undefined
    let direction: 'inbound' | 'outbound' | undefined
    if (messageStatistics.value.length > 0) {
      // Find the most recent stateSnapshot statistics entry
      for (let i = messageStatistics.value.length - 1; i >= 0; i--) {
        const stat = messageStatistics.value[i]
        if (stat.messageType === 'stateSnapshot' && stat.direction === 'inbound') {
          messageSize = stat.messageSize
          direction = stat.direction
          break
        }
      }
    }
    
    stateUpdates.value.push({
      id: Date.now().toString() + Math.random().toString(36).substr(2, 9),
      timestamp: new Date(),
      type: 'snapshot',
      message: '初始狀態已接收 (完整快照)',
      // Debug information
      tickId: tickId,
      messageSize: messageSize,
      direction: direction || 'inbound',
      landID: currentLandID.value,
      playerID: currentPlayerID.value || undefined,
      sequenceNumber: updateSequenceNumber++
    })

    // Keep only last 1000 updates, remove oldest if exceeded
    if (stateUpdates.value.length > 1000) {
      stateUpdates.value = stateUpdates.value.slice(-1000)
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
      
      // Set up statistics callback to collect actual message sizes from SDK
      runtime.setStatisticsCallback((stats: RawMessageStatistics) => {
        const entry: MessageStatistics = {
          ...stats,
          sequence: statsSequenceNumber++
        }
        // Use array spread to ensure Vue reactivity
        messageStatistics.value = [...messageStatistics.value, entry]
        // Keep only last 1000 statistics entries
        if (messageStatistics.value.length > 1000) {
          messageStatistics.value = messageStatistics.value.slice(-1000)
        }
      })
      
      // Set up disconnect callback to handle connection errors
      runtime.onDisconnect((closeCode, closeReason, wasClean) => {
        if (isConnected.value) {
          isConnected.value = false
          const wasJoined = isJoined.value
          isJoined.value = false
          
          // Try to parse closeReason as JSON (server may send structured error)
          let parsedReason: any = null
          let reasonText = closeReason || ''
          try {
            if (closeReason && closeReason.trim().startsWith('{')) {
              parsedReason = JSON.parse(closeReason)
              reasonText = parsedReason.message || parsedReason.code || closeReason
            }
          } catch {
            // Not JSON, use as-is
          }
          
          // WebSocket close codes:
          // 1000 = Normal Closure
          // 1001 = Going Away
          // 1002 = Protocol Error
          // 1003 = Unsupported Data
          // 1006 = Abnormal Closure (no close frame received)
          // 1007 = Invalid frame payload data
          // 1008 = Policy Violation (e.g., JWT validation failed)
          // 1009 = Message too big
          // 1011 = Internal Server Error
          // 1012 = Service Restart
          // 1013 = Try Again Later
          // 1014 = Bad Gateway
          // 1015 = TLS Handshake
          
          let errorMessage = ''
          let userFriendlyError = ''
          
          if (closeCode === 1008) {
            // Policy Violation - often JWT validation failure
            if (parsedReason) {
              userFriendlyError = `連線被拒絕: ${reasonText}`
              if (parsedReason.code === 'WEBSOCKET_INVALID_TOKEN') {
                userFriendlyError = `JWT Token 驗證失敗: ${reasonText}`
              }
            } else {
              userFriendlyError = `連線被拒絕（政策違規）: ${reasonText || '可能是 JWT token 驗證失敗'}`
            }
            errorMessage = `❌ ${userFriendlyError}`
          } else if (closeCode === 1006) {
            userFriendlyError = `連線異常關閉: ${reasonText || '可能是網路問題或伺服器錯誤'}`
            errorMessage = `❌ ${userFriendlyError}`
          } else if (closeCode === 1011) {
            userFriendlyError = `伺服器內部錯誤: ${reasonText || '伺服器處理請求時發生錯誤'}`
            errorMessage = `❌ ${userFriendlyError}`
          } else if (closeCode !== 1000) {
            userFriendlyError = `連線關閉 (code=${closeCode}): ${reasonText || '未知原因'}`
            errorMessage = `❌ ${userFriendlyError}`
          } else {
            userFriendlyError = `連線正常關閉: ${reasonText || '正常關閉'}`
            errorMessage = `ℹ️  ${userFriendlyError}`
          }
          
          // Add wasClean info for debugging
          if (!wasClean && closeCode !== 1000) {
            errorMessage += ' (非正常關閉)'
          }
          
          // Set connection error for UI display
          if (closeCode !== 1000) {
            connectionError.value = userFriendlyError
          } else {
            connectionError.value = null
          }
          
          // If we were in the process of joining or were joined, this might be an error
          if (wasJoined) {
            addLog(`${errorMessage}（已加入狀態）`, 'error')
          } else if (closeCode !== 1000) {
            addLog(errorMessage, 'error')
          } else {
            addLog(errorMessage, 'info')
          }
        }
      })
      
      console.log('[Playground] Runtime created, connecting...')
      try {
        await runtime.connect(urlToUse)
        console.log('[Playground] Connection completed')
      } catch (connectError: any) {
        // Connection failed during handshake
        // SDK already formats a user-friendly error message, but we can enhance it for Playground
        const errorMessage = connectError?.message || String(connectError)
        const closeCode = connectError?.closeCode
        
        // SDK already provides a formatted error message, but we can add emoji for Playground UI
        let formattedError = `❌ ${errorMessage}`
        if (closeCode !== undefined && closeCode !== null && closeCode !== 1000) {
          // Add close code info if not already in the message
          if (!errorMessage.includes(`code=${closeCode}`)) {
            formattedError += ` (code=${closeCode})`
          }
        }
        
        connectionError.value = formattedError
        addLog(formattedError, 'error')
        isConnected.value = false
        throw connectError // Re-throw to be caught by outer catch
      }

      isConnected.value = true
      isJoined.value = false
      connectionError.value = null
      addLog('✅ WebSocket 連線成功', 'success')

      // Use current landID (from selectedLandID or fallback)
      const landIDToUse = currentLandID.value || getInitialLandID()
      
      // Check if schema is available
      if (!schema.value) {
        throw new Error('Schema is required. Please load schema before connecting.')
      }
      
      // Create view with state update callbacks
      view = runtime.createView(landIDToUse, {
        schema: schema.value as any, // Schema type is compatible with ProtocolSchema
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
          // Special handling for error messages to make them more visible
          if (message.kind === 'error') {
            const errorPayload = (message.payload as any).error || message.payload
            const code = errorPayload?.code || 'UNKNOWN_ERROR'
            const errorMessage = errorPayload?.message || 'Unknown error'
            const details = errorPayload?.details || {}
            addLog(
              `❌ 錯誤 [${code}]: ${errorMessage}${details ? ` (${JSON.stringify(details)})` : ''}`,
              'error',
              message
            )
          } else {
            addLog(`Transport message [${message.kind}]`, 'server', message)
          }
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

      // Join automatically with timeout
      try {
        // Set a timeout for join operation (10 seconds)
        const joinPromise = view.join()
        const timeoutPromise = new Promise((_, reject) => {
          setTimeout(() => reject(new Error('Join timeout: 伺服器沒有回應')), 10000)
        })
        
        const joinResult = await Promise.race([joinPromise, timeoutPromise]) as any
        if (joinResult.success) {
          isJoined.value = true
          
          // Update current landID from join result or view's current landID
          // The view automatically updates its landID if server returns a different one
          const actualLandID = joinResult.landID || view.getCurrentLandID() || currentLandID.value
          if (actualLandID !== currentLandID.value) {
            currentLandID.value = actualLandID
            if (actualLandID !== landIDToUse) {
              addLog(`ℹ️  LandID 已更新: ${landIDToUse} -> ${actualLandID}`, 'info')
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
        isJoined.value = false
        const errorMessage = err instanceof Error ? err.message : String(err)
        addLog(`❌ Join 失敗: ${errorMessage}`, 'error')
        
        // If connection is still open but join failed, it might be an authentication error
        if (isConnected.value && !isJoined.value) {
          addLog('⚠️  可能是 JWT token 驗證失敗或其他認證問題', 'warning')
        }
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
      runtime.setStatisticsCallback(null) // Clear statistics callback
      runtime.disconnect()
      runtime = null
      view = null
    }
    isConnected.value = false
    isJoined.value = false
    currentState.value = {}
    logs.value = []
    stateUpdates.value = []
    messageStatistics.value = [] // Reset statistics
    statsSequenceNumber = 0
    currentLandID.value = getInitialLandID()  // Reset to initial value
    currentPlayerID.value = null
  }

  const sendAction = (actionName: string, payload: any, _landID?: string, requestID?: string): void => {
    if (!view) {
      addLog('❌ 尚未連線或加入遊戲', 'error')
      return
    }
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

  const sendEvent = (eventName: string, payload: any, _landID?: string): void => {
    if (!view) {
      addLog('❌ 尚未連線或加入遊戲', 'error')
      return
    }
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
    messageStatistics, // Actual message statistics from SDK
    actionResults,
    connect,
    disconnect,
    sendAction,
    sendEvent
  }
}
