import { ref, Ref, computed } from 'vue'
import type { Schema, TransportMessage } from '@/types'
import type { LogEntry } from '@/types/transport'

export function useWebSocket(wsUrl: Ref<string>, schema: Ref<Schema | null>) {
  const ws = ref<WebSocket | null>(null)
  const isConnected = ref(false)
  const currentState = ref<Record<string, any>>({})
  const logs = ref<LogEntry[]>([])

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
        addLog('✅ WebSocket 連線成功', 'success')
      }

      ws.value.onerror = (error) => {
        addLog(`❌ WebSocket 錯誤: ${error}`, 'error')
      }

      ws.value.onclose = (event) => {
        isConnected.value = false
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
            const data = JSON.parse(text) as TransportMessage | any
            addLog('📥 收到訊息', 'server', data)

            if (data && typeof data === 'object' && 'values' in data && data.values && typeof data.values === 'object') {
              const decodedState: Record<string, any> = {}
              for (const [key, value] of Object.entries(data.values as Record<string, any>)) {
                decodedState[key] = decodeSnapshotValue(value)
              }
              currentState.value = decodedState
              addLog('📊 狀態已更新', 'info', decodedState)
            } else if (data.event?.event?.fromServer) {
              const eventData = data.event.event.fromServer
              addLog(`📨 伺服器事件: ${JSON.stringify(eventData)}`, 'server')
            } else if (data.actionResponse) {
              addLog(`✅ Action 回應: ${JSON.stringify(data.actionResponse.response)}`, 'success')
            } else {
              addLog('ℹ️ 未知訊息格式', 'warning', data)
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
    const message: TransportMessage = {
      event: {
        landID,
        event: {
          fromClient: {
            [eventName]: payload
          }
        }
      }
    }

    sendMessage(message)
  }

  return {
    isConnected,
    currentState,
    logs,
    connect,
    disconnect,
    sendAction,
    sendEvent
  }
}
