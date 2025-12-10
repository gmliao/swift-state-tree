import { ref, type Ref } from 'vue'
import type { LogEntry } from '@/types/transport'
import type { Logger } from '@swiftstatetree/sdk/core'

/**
 * Playground-specific logger that adds logs to Vue refs
 */
export function createPlaygroundLogger(
  logs: Ref<LogEntry[]>
): Logger {
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

  const loggerImpl: Logger = {
    debug(message: string, data?: any): void {
      console.log('[SDK DEBUG]', message, data)
      addLog(`[DEBUG] ${message}`, 'info', data)
    },
    info(message: string, data?: any): void {
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

