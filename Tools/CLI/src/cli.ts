#!/usr/bin/env node

import { Command } from 'commander'
import { readFileSync, statSync, readdirSync } from 'fs'
import { join, basename } from 'path'
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
  .option('--schema-url <url>', 'Schema base URL (defaults to WebSocket host)')
  .option('--state-update-encoding <mode>', 'State update decoding mode (auto|jsonObject|opcodeJsonArray|messagepack)', 'auto')
  .option('-s, --script <file_or_dir>', 'Script file or directory of scripts to execute after joining')
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

      // Fetch schema (required by StateTreeView)
      const schemaBaseUrl = options.schemaUrl ?? deriveSchemaBaseUrl(wsUrl)
      const schema = await fetchSchema(schemaBaseUrl)

      // Create runtime and view
      const logger = new ChalkLogger()
      const transportEncoding = buildTransportEncoding(options.stateUpdateEncoding)
      const runtime = new StateTreeRuntime({ logger, transportEncoding })
      await runtime.connect(wsUrl)

      const view = runtime.createView(options.land, {
        schema: schema as any,
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
        const stats = statSync(options.script)
        const scripts = stats.isDirectory() 
          ? readdirSync(options.script).filter(f => f.endsWith('.json')).map(f => join(options.script, f))
          : [options.script]

        console.log(chalk.blue(`📂 Found ${scripts.length} script(s) to execute.`))

        let allPassed = true
        for (const scriptPath of scripts) {
          try {
            await executeScript(view, scriptPath)
          } catch (scriptError) {
            console.error(chalk.red(`\n❌ Script execution error in ${basename(scriptPath)}: ${scriptError}`))
            allPassed = false
            // Fail fast: if one script in directory fails, stop
            break
          }
        }
        
        if (!allPassed) {
          console.error(chalk.red('\n❌ Some tests failed. Halting.'))
          process.exit(1)
        }

        // Wait for responses and then auto-exit
        const timeoutSeconds = parseInt(options.timeout || '10', 10)
        console.log(chalk.gray(`\n⏳ Waiting ${timeoutSeconds}s for final responses, then auto-exit...`))
        
        try {
          for (let i = timeoutSeconds; i > 0; i--) {
            await new Promise(resolve => setTimeout(resolve, 1000))
            process.stdout.write(chalk.gray(`\r⏳ ${i}s remaining...`))
          }
          console.log() 
        } catch (countdownError) {
          console.log()
        }
        
        console.log(chalk.yellow('\n👋 Disconnecting...'))
        await runtime.disconnect()
        process.exit(0)
      } else if (options.once) {
        console.log(chalk.green('\n✅ Connected and joined successfully!'))
        runtime.disconnect()
        process.exit(0)
      } else {
        console.log(chalk.green('\n✅ Connected and joined successfully!'))
        console.log(chalk.yellow('Use Ctrl+C to exit\n'))
        console.log(chalk.cyan('Note: Interactive command input is not yet implemented.'))
        
        process.on('SIGINT', async () => {
          console.log(chalk.yellow('\n👋 Disconnecting...'))
          await runtime.disconnect()
          process.exit(0)
        })

        await new Promise(() => {}) 
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
  .description('Execute a test script or directory of scripts')
  .requiredOption('-u, --url <url>', 'WebSocket URL')
  .requiredOption('-l, --land <landID>', 'Land ID to join')
  .requiredOption('-s, --script <file_or_dir>', 'Script file or directory to execute')
  .option('-p, --player <playerID>', 'Player ID')
  .option('-d, --device <deviceID>', 'Device ID')
  .option('-m, --metadata <json>', 'Metadata as JSON string')
  .option('-t, --token <token>', 'JWT token for authentication')
  .option('--schema-url <url>', 'Schema base URL (defaults to WebSocket host)')
  .option('--state-update-encoding <mode>', 'State update decoding mode (auto|jsonObject|opcodeJsonArray|messagepack)', 'auto')
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

      const schemaBaseUrl = options.schemaUrl ?? deriveSchemaBaseUrl(wsUrl)
      const schema = await fetchSchema(schemaBaseUrl)

      const stats = statSync(options.script)
      const scripts = stats.isDirectory() 
        ? readdirSync(options.script).filter(f => f.endsWith('.json')).map(f => join(options.script, f))
        : [options.script]

      console.log(chalk.blue(`📂 Executing ${scripts.length} script(s).`))

      for (const scriptPath of scripts) {
        // Create a new runtime connection for each script to avoid "Already joined a land" error
        const logger = new ChalkLogger()
        const transportEncoding = buildTransportEncoding(options.stateUpdateEncoding)
        const runtime = new StateTreeRuntime({ logger, transportEncoding })
        
        try {
          await runtime.connect(wsUrl)
          
          // Read script to check for landID override
          const scriptContent = readFileSync(scriptPath, 'utf-8')
          const script = JSON.parse(scriptContent)
          
          // Determine land ID: respect full land IDs, only append random instance for bare land types
          // If options.land already contains ':', it's a full land ID - use it as-is
          // Otherwise, it's a bare land type - append instance ID
          let landID: string
          if (options.land.includes(':')) {
            // Full land ID provided (e.g., "cookie:room-123") - use it directly
            landID = options.land
          } else {
            // Bare land type provided (e.g., "cookie") - append instance ID
            // Use script.landID if specified, otherwise generate unique instance ID
            const uniqueInstanceId = script.landID 
              ? (script.landID.includes(':') ? script.landID.split(':')[1] : script.landID)
              : `test-${Date.now()}-${Math.random().toString(36).substring(2, 9)}`
            landID = `${options.land}:${uniqueInstanceId}`
          }
          
          console.log(chalk.cyan(`🏠 Using land ID: ${landID}`))
          
          // Create a new view with unique land ID for each script
          const view = runtime.createView(landID, {
            schema: schema as any,
            playerID: options.player,
            deviceID: options.device,
            metadata,
            logger
          })
          
          const joinResult = await view.join()
          if (!joinResult.success) {
            throw new Error(`Failed to join land ${landID}: ${joinResult.reason || 'Unknown reason'}`)
          }
          console.log(chalk.green(`✅ Joined land: ${joinResult.landID || landID}`))
          
          await executeScript(view, scriptPath, script)
          
          // Disconnect runtime after script completes
          runtime.disconnect()
        } catch (scriptError) {
          console.error(chalk.red(`\n❌ Script execution error in ${basename(scriptPath)}: ${scriptError}`))
          runtime.disconnect()
          process.exit(1)
        }
      }
      
      console.log(chalk.yellow('\n👋 All scripts completed successfully'))
      process.exit(0)
    } catch (error) {
      console.error(chalk.red(`Error: ${error}`))
      process.exit(1)
    }
  })

async function executeScript(view: StateTreeView, scriptPath: string, script?: any) {
  try {
    // If script is already parsed, use it; otherwise read from file
    if (!script) {
      const scriptContent = readFileSync(scriptPath, 'utf-8')
      script = JSON.parse(scriptContent)
    }

    console.log(chalk.blue(`📜 Executing scenario: ${basename(scriptPath)}`))
    
    // Default max duration if not specified
    const maxDuration = script.maxDuration || 60000 // 60 seconds default
    const startTime = Date.now()

    for (const step of script.steps || []) {
      // Check for global timeout
      if (Date.now() - startTime > maxDuration) {
        throw new Error(`Scenario exceeded maximum duration of ${maxDuration}ms`)
      }

      const { type, action, event, payload, wait, assert, expectError, errorCode, errorMessage } = step

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
            throw new Error(`Expected action [${action}] to fail but it succeeded`)
          } else {
            console.log(chalk.green(`✅ Action [${action}] response received`))
          }
        } catch (error: any) {
          if (isExpectedError) {
            const errorCodeMatch = !errorCode || (error as any)?.code === errorCode || error?.message?.includes(errorCode)
            const errorMessageMatch = !errorMessage || error?.message?.includes(errorMessage)
            
            if (errorCodeMatch && errorMessageMatch) {
              console.log(chalk.green(`✅ Action [${action}] failed as expected`))
            } else {
              console.warn(chalk.yellow(`⚠️  Action [${action}] failed but didn't match criteria. Continuing...`))
            }
          } else {
            console.error(chalk.red(`❌ Action [${action}] failed unexpectedly: ${error?.message || error}`))
            throw error // In E2E, unexpected failures should stop the test
          }
        }
      } else if (type === 'event' && event) {
        console.log(chalk.blue(`📤 Sending event [${event}]...`))
        view.sendEvent(event, payload || {})
      } else if (type === 'assert') {
        const { path, equals, exists, greaterThanOrEqual, message } = assert
        const state = view.getState()
        const value = getNestedValue(state, path)
        
        console.log(chalk.magenta(`🔍 Asserting: ${path} ...`))
        
        if (exists !== undefined) {
          const isPresent = value !== undefined
          if (isPresent !== exists) {
            throw new Error(message || `Assertion failed: path ${path} presence should be ${exists}, but got ${isPresent}`)
          }
        }
        
        if (equals !== undefined) {
          if (JSON.stringify(value) !== JSON.stringify(equals)) {
            throw new Error(message || `Assertion failed: ${path} expected ${JSON.stringify(equals)}, but got ${JSON.stringify(value)}`)
          }
        }
        
        if (greaterThanOrEqual !== undefined) {
          const numValue = typeof value === 'number' ? value : Number(value)
          const numExpected = typeof greaterThanOrEqual === 'number' ? greaterThanOrEqual : Number(greaterThanOrEqual)
          if (isNaN(numValue) || isNaN(numExpected) || numValue < numExpected) {
            throw new Error(message || `Assertion failed: ${path} expected >= ${greaterThanOrEqual}, but got ${value}`)
          }
        }
        console.log(chalk.green(`✅ Assertion passed: ${path}`))
      } else if (type === 'log') {
        console.log(chalk.cyan(`ℹ️  ${step.message || ''}`))
      } else if (type === 'state') {
        const state = view.getState()
        console.log(chalk.yellow(`📊 Current state: ${JSON.stringify(state, null, 2)}`))
      }
    }

    console.log(chalk.green(`✅ Scenario completed: ${basename(scriptPath)}\n`))
  } catch (error) {
    console.error(chalk.red(`❌ Scenario failed: ${basename(scriptPath)}: ${error}`))
    throw error
  }
}

function getNestedValue(obj: any, path: string): any {
  if (!path) return obj
  return path.split('.').reduce((o, i) => (o ? o[i] : undefined), obj)
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

function deriveSchemaBaseUrl(wsUrl: string): string {
  const url = new URL(wsUrl)
  const schemaProtocol = url.protocol === 'wss:' ? 'https:' : 'http:'
  return `${schemaProtocol}//${url.host}`
}

function buildTransportEncoding(stateUpdateEncoding?: string) {
  const normalized = (stateUpdateEncoding ?? 'auto').toLowerCase()
  
  // Handle messagepack mode
  // Note: When message is messagepack, stateUpdate is also messagepack format (opcodeMessagePack)
  // TypeScript types don't include opcodeMessagePack, so we use 'auto' decoding
  // The SDK will automatically detect binary format and decode correctly
  if (normalized === 'messagepack' || normalized === 'msgpack') {
    return {
      message: 'messagepack',
      stateUpdate: 'opcodeJsonArray', // Type doesn't support opcodeMessagePack, but decoding will handle it
      stateUpdateDecoding: 'auto' // Auto-detect messagepack format from binary data
    } as const
  }
  
  // Handle opcodeJsonArray mode
  if (normalized === 'opcodejsonarray') {
    return {
      message: 'opcodeJsonArray',
      stateUpdate: 'opcodeJsonArray',
      stateUpdateDecoding: 'opcodeJsonArray'
    } as const
  }
  
  // Handle jsonObject mode (default)
  if (normalized === 'jsonobject' || normalized === 'auto') {
    return {
      message: 'json',
      stateUpdate: 'jsonObject',
      stateUpdateDecoding: 'jsonObject'
    } as const
  }
  
  // Default fallback
  return {
    message: 'json',
    stateUpdate: 'jsonObject',
    stateUpdateDecoding: 'jsonObject'
  } as const
}
