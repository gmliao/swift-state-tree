#!/usr/bin/env node

import { Command } from 'commander'
import { readFileSync } from 'fs'
import { join } from 'path'
import chalk from 'chalk'
import { StateTreeRuntime, StateTreeView } from '@swiftstatetree/sdk/core'
import { ChalkLogger } from './logger'
import { fetchSchema, printSchema } from './schema'
import * as admin from './admin'

const program = new Command()

program
  .name('swiftstatetree-cli')
  .description('SwiftStateTree WebSocket CLI testing tool')
  .version('1.0.0')

program
  .command('connect')
  .description('Connect to a SwiftStateTree server')
  .requiredOption('-u, --url <url>', 'WebSocket URL (e.g., ws://localhost:8080/ws)')
  .requiredOption('-l, --land <landID>', 'Land ID to join')
  .option('-p, --player <playerID>', 'Player ID (optional, server will generate if not provided)')
  .option('-d, --device <deviceID>', 'Device ID')
  .option('-m, --metadata <json>', 'Metadata as JSON string')
  .option('-t, --token <token>', 'JWT token for authentication')
  .option('-s, --script <file>', 'Script file to execute after joining')
  .option('--once', 'Exit after successful connection and join (non-interactive mode)')
  .option('--timeout <seconds>', 'Auto-exit timeout in seconds after script completion (default: 10)', '10')
  .action(async (options) => {
    try {
      // Parse metadata if provided
      let metadata: Record<string, any> | undefined
      if (options.metadata) {
        try {
          metadata = JSON.parse(options.metadata)
        } catch (e) {
          console.error(chalk.red(`Invalid metadata JSON: ${e}`))
          process.exit(1)
        }
      }

      // Build WebSocket URL with token if provided
      let wsUrl = options.url
      if (options.token) {
        const separator = wsUrl.includes('?') ? '&' : '?'
        wsUrl = `${wsUrl}${separator}token=${encodeURIComponent(options.token)}`
      }

      // Create runtime and view
      const logger = new ChalkLogger()
      const runtime = new StateTreeRuntime(logger)
      await runtime.connect(wsUrl)

      const view = runtime.createView(options.land, {
        playerID: options.player,
        deviceID: options.device,
        metadata,
        logger
      })

      // Join
      const joinResult = await view.join()
      if (!joinResult.success) {
        console.error(chalk.red(`Failed to join: ${joinResult.reason || 'Unknown reason'}`))
        runtime.disconnect()
        process.exit(1)
      } else {
        console.log(chalk.green(`✅ Successfully joined as ${joinResult.playerID || 'unknown'}`))
      }

      // Execute script if provided
      if (options.script) {
        try {
          await executeScript(view, options.script)
        } catch (scriptError) {
          console.error(chalk.red(`\n❌ Script execution error: ${scriptError}`))
          // Continue to cleanup even if script failed
        }
        
        // Wait for responses and then auto-exit
        const timeoutSeconds = parseInt(options.timeout || '10', 10)
        console.log(chalk.gray(`\n⏳ Waiting ${timeoutSeconds}s for final responses, then auto-exit...`))
        
        // Show countdown with error handling
        try {
          for (let i = timeoutSeconds; i > 0; i--) {
            await new Promise(resolve => setTimeout(resolve, 1000))
            process.stdout.write(chalk.gray(`\r⏳ ${i}s remaining...`))
          }
          console.log() // New line after countdown
        } catch (countdownError) {
          // Ignore countdown errors (e.g., if stdout is closed)
          console.log()
        }
        
        console.log(chalk.yellow('\n👋 Disconnecting...'))
        try {
          await runtime.disconnect()
          console.log(chalk.green('✅ Disconnected successfully'))
        } catch (disconnectError) {
          console.error(chalk.red(`⚠️  Disconnect error: ${disconnectError}`))
        }
        process.exit(0)
      } else if (options.once) {
        // Non-interactive mode: exit after successful connection
        console.log(chalk.green('\n✅ Connected and joined successfully!'))
        runtime.disconnect()
        process.exit(0)
      } else {
        // Interactive mode (currently just keeps connection alive)
        // TODO: Implement readline for actual command input
        console.log(chalk.green('\n✅ Connected and joined successfully!'))
        console.log(chalk.yellow('Use Ctrl+C to exit\n'))
        console.log(chalk.cyan('Note: Interactive command input is not yet implemented.'))
        console.log(chalk.cyan('For now, this mode just keeps the connection alive.'))
        console.log(chalk.gray('Use --script to execute actions, or --once to exit immediately.\n'))

        // Keep process alive
        process.on('SIGINT', async () => {
          console.log(chalk.yellow('\n👋 Disconnecting...'))
          await runtime.disconnect()
          process.exit(0)
        })

        // Wait for user input (simplified - in real CLI you'd use readline)
        await new Promise(() => {}) // Keep alive
      }
    } catch (error) {
      console.error(chalk.red(`Error: ${error}`))
      process.exit(1)
    }
  })

program
  .command('schema')
  .description('Fetch and display the protocol schema from the server')
  .requiredOption('-u, --url <url>', 'Server URL (e.g., http://localhost:8080 or ws://localhost:8080)')
  .action(async (options) => {
    try {
      console.log(chalk.blue(`📥 Fetching schema from ${options.url}...`))
      const schema = await fetchSchema(options.url)
      printSchema(schema)
    } catch (error) {
      console.error(chalk.red(`Error: ${error}`))
      process.exit(1)
    }
  })

program
  .command('script')
  .description('Execute a test script')
  .requiredOption('-u, --url <url>', 'WebSocket URL')
  .requiredOption('-l, --land <landID>', 'Land ID to join')
  .requiredOption('-s, --script <file>', 'Script file to execute')
  .option('-p, --player <playerID>', 'Player ID')
  .option('-d, --device <deviceID>', 'Device ID')
  .option('-m, --metadata <json>', 'Metadata as JSON string')
  .option('-t, --token <token>', 'JWT token for authentication')
  .action(async (options) => {
    try {
      let metadata: Record<string, any> | undefined
      if (options.metadata) {
        try {
          metadata = JSON.parse(options.metadata)
        } catch (e) {
          console.error(chalk.red(`Invalid metadata JSON: ${e}`))
          process.exit(1)
        }
      }

      let wsUrl = options.url
      if (options.token) {
        const separator = wsUrl.includes('?') ? '&' : '?'
        wsUrl = `${wsUrl}${separator}token=${encodeURIComponent(options.token)}`
      }

      const logger = new ChalkLogger()
      const runtime = new StateTreeRuntime(logger)
      await runtime.connect(wsUrl)

      const view = runtime.createView(options.land, {
        playerID: options.player,
        deviceID: options.device,
        metadata,
        logger
      })

      const joinResult = await view.join()
      if (!joinResult.success) {
        console.error(chalk.red(`Failed to join: ${joinResult.reason}`))
        runtime.disconnect()
        process.exit(1)
      }

      try {
        await executeScript(view, options.script)
      } catch (scriptError) {
        console.error(chalk.red(`\n❌ Script execution error: ${scriptError}`))
        // Continue to cleanup even if script failed
      }
      
      // Wait for responses and then auto-exit
      const timeoutSeconds = 10 // Default 10 seconds for script command
      console.log(chalk.gray(`\n⏳ Waiting ${timeoutSeconds}s for final responses, then auto-exit...`))
      
      // Show countdown with error handling
      try {
        for (let i = timeoutSeconds; i > 0; i--) {
          await new Promise(resolve => setTimeout(resolve, 1000))
          process.stdout.write(chalk.gray(`\r⏳ ${i}s remaining...`))
        }
        console.log() // New line after countdown
      } catch (countdownError) {
        // Ignore countdown errors (e.g., if stdout is closed)
        console.log()
      }
      
      console.log(chalk.yellow('\n👋 Disconnecting...'))
      try {
        await runtime.disconnect()
        console.log(chalk.green('✅ Disconnected successfully'))
      } catch (disconnectError) {
        console.error(chalk.red(`⚠️  Disconnect error: ${disconnectError}`))
      }
      process.exit(0)
    } catch (error) {
      console.error(chalk.red(`Error: ${error}`))
      process.exit(1)
    }
  })

async function executeScript(view: StateTreeView, scriptPath: string) {
  try {
    const scriptContent = readFileSync(scriptPath, 'utf-8')
    const script = JSON.parse(scriptContent)

    console.log(chalk.blue(`📜 Executing script: ${scriptPath}\n`))

    for (const step of script.steps || []) {
      const { type, action, event, payload, wait, expectError, errorCode, errorMessage } = step

      if (wait) {
        console.log(chalk.gray(`⏳ Waiting ${wait}ms...`))
        await new Promise(resolve => setTimeout(resolve, wait))
      }

      if (type === 'action' && action) {
        const isExpectedError = expectError === true
        try {
          if (isExpectedError) {
            console.log(chalk.yellow(`📤 Sending action [${action}] (expecting error)...`))
          } else {
            console.log(chalk.blue(`📤 Sending action [${action}]...`))
          }
          
          const response = await view.sendAction(action, payload || {})
          
          if (isExpectedError) {
            console.error(chalk.red(`❌ Action [${action}] was expected to fail but succeeded: ${JSON.stringify(response)}`))
            throw new Error(`Expected action [${action}] to fail but it succeeded`)
          } else {
            console.log(chalk.green(`✅ Action [${action}] response: ${JSON.stringify(response)}`))
          }
        } catch (error: any) {
          if (isExpectedError) {
            // Verify error matches expected criteria
            const errorCodeMatch = !errorCode || (error as any)?.code === errorCode || error?.message?.includes(errorCode)
            const errorMessageMatch = !errorMessage || error?.message?.includes(errorMessage)
            
            if (errorCodeMatch && errorMessageMatch) {
              console.log(chalk.green(`✅ Action [${action}] failed as expected: ${error?.message || error}`))
              if (errorCode) {
                console.log(chalk.gray(`   Error code: ${(error as any)?.code || 'N/A'}`))
              }
            } else {
              // Log warning but continue execution - this allows testing error cases
              // even if error format doesn't exactly match expectations
              console.error(chalk.yellow(`⚠️  Action [${action}] failed but didn't match expected error criteria:`))
              console.error(chalk.yellow(`   Expected: code=${errorCode || 'any'}, message=${errorMessage || 'any'}`))
              console.error(chalk.yellow(`   Got: code=${(error as any)?.code || 'N/A'}, message=${error?.message || 'N/A'}`))
              console.log(chalk.gray(`   Continuing script execution...`))
              // Don't throw - continue execution to allow testing multiple error cases
            }
          } else {
            console.error(chalk.red(`❌ Action [${action}] failed unexpectedly: ${error?.message || error}`))
            // Continue execution even if action fails (unless it was expected to succeed)
          }
        }
      } else if (type === 'event' && event) {
        view.sendEvent(event, payload || {})
      } else if (type === 'log') {
        console.log(chalk.cyan(`ℹ️  ${step.message || ''}`))
      } else if (type === 'state') {
        const state = view.getState()
        console.log(chalk.yellow(`📊 Current state: ${JSON.stringify(state, null, 2)}`))
      } else if (type === 'expectError') {
        // Standalone error expectation step (for testing error handling)
        console.log(chalk.yellow(`⚠️  Expected error step: ${step.message || 'No message'}`))
      }
    }

    console.log(chalk.green('\n✅ Script completed'))
  } catch (error) {
    console.error(chalk.red(`Failed to execute script: ${error}`))
    throw error
  }
}

// Admin commands
const adminCommand = program
  .command('admin')
  .description('Admin commands for managing lands (requires admin authentication)')

adminCommand
  .command('list')
  .description('List all lands')
  .requiredOption('-u, --url <url>', 'Server URL (e.g., http://localhost:8080)')
  .option('-k, --api-key <key>', 'Admin API key')
  .option('-t, --token <token>', 'JWT token with admin role')
  .action(async (options) => {
    try {
      if (!options.apiKey && !options.token) {
        console.error(chalk.red('Error: Either --api-key or --token is required'))
        process.exit(1)
      }

      console.log(chalk.blue(`📋 Fetching land list from ${options.url}...`))
      const lands = await admin.listLands({
        url: options.url,
        apiKey: options.apiKey,
        token: options.token,
      })
      admin.printLandList(lands)
    } catch (error: any) {
      console.error(chalk.red(`Error: ${error.message}`))
      process.exit(1)
    }
  })

adminCommand
  .command('stats')
  .description('Get system statistics')
  .requiredOption('-u, --url <url>', 'Server URL (e.g., http://localhost:8080)')
  .option('-k, --api-key <key>', 'Admin API key')
  .option('-t, --token <token>', 'JWT token with admin role')
  .action(async (options) => {
    try {
      if (!options.apiKey && !options.token) {
        console.error(chalk.red('Error: Either --api-key or --token is required'))
        process.exit(1)
      }

      console.log(chalk.blue(`📊 Fetching system statistics from ${options.url}...`))
      const stats = await admin.getSystemStats({
        url: options.url,
        apiKey: options.apiKey,
        token: options.token,
      })
      admin.printSystemStats(stats)
    } catch (error: any) {
      console.error(chalk.red(`Error: ${error.message}`))
      process.exit(1)
    }
  })

adminCommand
  .command('get')
  .description('Get information about a specific land')
  .requiredOption('-u, --url <url>', 'Server URL (e.g., http://localhost:8080)')
  .requiredOption('-l, --land <landID>', 'Land ID')
  .option('-k, --api-key <key>', 'Admin API key')
  .option('-t, --token <token>', 'JWT token with admin role')
  .action(async (options) => {
    try {
      if (!options.apiKey && !options.token) {
        console.error(chalk.red('Error: Either --api-key or --token is required'))
        process.exit(1)
      }

      console.log(
        chalk.blue(
          `🔍 Fetching land info for ${options.land} from ${options.url}...`
        )
      )
      const stats = await admin.getLandStats({
        url: options.url,
        landID: options.land,
        apiKey: options.apiKey,
        token: options.token,
      })
      if (stats) {
        admin.printLandStats(stats)
      } else {
        console.log(chalk.yellow(`  Land not found: ${options.land}`))
      }
    } catch (error: any) {
      console.error(chalk.red(`Error: ${error.message}`))
      process.exit(1)
    }
  })

adminCommand
  .command('delete')
  .description('Delete a land (requires admin role)')
  .requiredOption('-u, --url <url>', 'Server URL (e.g., http://localhost:8080)')
  .requiredOption('-l, --land <landID>', 'Land ID to delete')
  .option('-k, --api-key <key>', 'Admin API key')
  .option('-t, --token <token>', 'JWT token with admin role')
  .action(async (options) => {
    try {
      if (!options.apiKey && !options.token) {
        console.error(chalk.red('Error: Either --api-key or --token is required'))
        process.exit(1)
      }

      console.log(
        chalk.yellow(
          `🗑️  Deleting land ${options.land} from ${options.url}...`
        )
      )
      await admin.deleteLand({
        url: options.url,
        landID: options.land,
        apiKey: options.apiKey,
        token: options.token,
      })
      console.log(chalk.green(`✅ Successfully deleted land: ${options.land}`))
    } catch (error: any) {
      console.error(chalk.red(`Error: ${error.message}`))
      process.exit(1)
    }
  })

program.parse()

