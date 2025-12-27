/**
 * Logger interface for SDK logging
 * Allows different implementations for different environments (CLI, Playground, etc.)
 */
export interface Logger {
  debug(message: string, data?: any): void
  info(message: string, data?: any): void
  warn(message: string, data?: any): void
  error(message: string, data?: any): void
}

/**
 * No-op logger that does nothing
 * Used as default logger to avoid console output when not needed
 */
export class NoOpLogger implements Logger {
  debug(_message: string, _data?: any): void {
    // No-op
  }

  info(_message: string, _data?: any): void {
    // No-op
  }

  warn(_message: string, _data?: any): void {
    // No-op
  }

  error(_message: string, _data?: any): void {
    // No-op
  }
}

/**
 * Console logger that outputs to console
 * Suitable for CLI and debugging
 */
export class ConsoleLogger implements Logger {
  debug(message: string, data?: any): void {
    if (data !== undefined) {
      console.debug(`[DEBUG] ${message}`, data)
    } else {
      console.debug(`[DEBUG] ${message}`)
    }
  }

  info(message: string, data?: any): void {
    if (data !== undefined) {
      console.log(`[INFO] ${message}`, data)
    } else {
      console.log(`[INFO] ${message}`)
    }
  }

  warn(message: string, data?: any): void {
    if (data !== undefined) {
      console.warn(`[WARN] ${message}`, data)
    } else {
      console.warn(`[WARN] ${message}`)
    }
  }

  error(message: string, data?: any): void {
    if (data !== undefined) {
      console.error(`[ERROR] ${message}`, data)
    } else {
      console.error(`[ERROR] ${message}`)
    }
  }
}

