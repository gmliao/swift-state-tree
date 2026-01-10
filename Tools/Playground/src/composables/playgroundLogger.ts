import { ref, type Ref } from 'vue'
import type { LogEntry } from '@/types/transport'
import type { Logger } from '@swiftstatetree/sdk/core'

/**
 * Playground-specific logger that adds logs to Vue refs
 */
export function createPlaygroundLogger(
  logs: Ref<LogEntry[]>,
  enableLogs: Ref<boolean> = ref(true)
): Logger {
  const addLog = (message: string, type: LogEntry['type'] = 'info', data?: any) => {
    // Skip if logging is disabled
    if (!enableLogs.value) {
      return
    }
    
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

  const loggerImpl: Logger = {
    debug(message: string, data?: any): void {
      // Debug messages from SDK (e.g. every state update) are very noisy.
      // We keep them in the browser console for troubleshooting, but do not
      // push them into the playground log panel.
      console.debug('[SDK DEBUG]', message, data)
    },
    info(message: string, data?: any): void {
      // Filter out high‑frequency state update logs – we already have a
      // dedicated StateUpdate panel for visualizing these.
      if (
        message.startsWith('📥 Received StateUpdate') ||
        message.startsWith('State update [') ||
        message.startsWith('📥 Received StateSnapshot')
      ) {
        console.debug('[SDK INFO]', message, data)
        return
      }
      console.log('[SDK INFO]', message, data)
      addLog(message, 'info', data)
    },
    warn(message: string, data?: any): void {
      console.warn('[SDK WARN]', message, data)
      addLog(message, 'warning', data)
    },
    error(message: string, data?: any): void {
      console.error('[SDK ERROR]', message, data)
      addLog(message, 'error', data)
    }
  }
  
  return loggerImpl
}

