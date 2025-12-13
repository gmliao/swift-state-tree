import chalk from 'chalk'
import type { Logger } from '@swiftstatetree/sdk/core'

/**
 * CLI-specific logger that uses chalk for colored output
 */
export class ChalkLogger implements Logger {
  debug(message: string, data?: any): void {
    if (data !== undefined) {
      console.log(chalk.gray(`[DEBUG] ${message}`), data)
    } else {
      console.log(chalk.gray(`[DEBUG] ${message}`))
    }
  }

  info(message: string, data?: any): void {
    if (data !== undefined) {
      console.log(chalk.blue(`[INFO] ${message}`), data)
    } else {
      console.log(chalk.blue(`[INFO] ${message}`))
    }
  }

  warn(message: string, data?: any): void {
    if (data !== undefined) {
      console.warn(chalk.yellow(`[WARN] ${message}`), data)
    } else {
      console.warn(chalk.yellow(`[WARN] ${message}`))
    }
  }

  error(message: string, data?: any): void {
    if (data !== undefined) {
      console.error(chalk.red(`[ERROR] ${message}`), data)
    } else {
      console.error(chalk.red(`[ERROR] ${message}`))
    }
  }
}

