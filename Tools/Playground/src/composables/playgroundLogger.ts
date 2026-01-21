import { ref, type Ref } from 'vue'
import type { LogEntry } from '@/types/transport'
import type { Logger } from '@swiftstatetree/sdk/core'

/**
 * Playground-specific logger that adds logs to Vue refs
 */
export function createPlaygroundLogger(
  logs: Ref<LogEntry[]>,
  enableLogs: Ref<boolean> = ref(true),
  debugConsoleEnabled: Ref<boolean> = ref(false)
): Logger {
  // Buffer for batched log updates
  const logBuffer: LogEntry[] = []
  let flushPending = false

  const flushLogs = () => {
    if (logBuffer.length === 0) {
      flushPending = false
      return
    }

    // Append buffer to logs
    logs.value.push(...logBuffer)
    logBuffer.length = 0 // Clear buffer

    // Keep only last 1000 logs
    if (logs.value.length > 1000) {
      // Remove excess from the beginning
      const excess = logs.value.length - 1000
      logs.value.splice(0, excess)
    }

    flushPending = false
  }

  const addLog = (message: string, type: LogEntry['type'] = 'info', data?: any) => {
    // Skip if logging is disabled
    if (!enableLogs.value) {
      return
    }
    
    logBuffer.push({
      id: Date.now().toString() + Math.random().toString(36).substr(2, 9),
      timestamp: new Date(),
      type,
      message,
      data
    })

    // Schedule flush if not already pending
    if (!flushPending) {
      flushPending = true
      // Use requestAnimationFrame for smoother UI updates, or setTimeout for throttling
      // setTimeout is safer for non-visual logic, but rAF aligns with render cycles
      requestAnimationFrame(flushLogs)
    }
  }

  const loggerImpl: Logger = {
    debug(message: string, data?: any): void {
      // Debug messages from SDK (e.g. every state update) are very noisy.
      // We keep them in the browser console for troubleshooting ONLY if debug console is enabled
      if (debugConsoleEnabled.value) {
        console.debug('[SDK DEBUG]', message, data)
      }
    },
    info(message: string, data?: any): void {
      // Filter out high‑frequency state update logs – we already have a
      // dedicated StateUpdate panel for visualizing these.
      if (
        message.startsWith('📥 Received StateUpdate') ||
        message.startsWith('State update [') ||
        message.startsWith('📥 Received StateSnapshot')
      ) {
        if (debugConsoleEnabled.value) {
          console.debug('[SDK INFO]', message, data)
        }
        return
      }
      
      if (debugConsoleEnabled.value) {
        console.log('[SDK INFO]', message, data)
      }
      addLog(message, 'info', data)
    },
    warn(message: string, data?: any): void {
      if (debugConsoleEnabled.value) {
        console.warn('[SDK WARN]', message, data)
      }
      addLog(message, 'warning', data)
    },
    error(message: string, data?: any): void {
      // Always log errors to console (per user request)
      console.error('[SDK ERROR]', message, data)
      addLog(message, 'error', data)
    }
  }
  
  return loggerImpl
}

