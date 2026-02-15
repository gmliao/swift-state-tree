#!/usr/bin/env tsx
/**
 * Test script to verify server can decode opcode array format messages from client
 * 
 * This script simulates a client sending opcode array format messages and verifies
 * the server can decode them correctly.
 */

import WebSocket from 'ws'
import chalk from 'chalk'

interface TestResult {
  test: string
  passed: boolean
  message: string
}

const results: TestResult[] = []

function logResult(test: string, passed: boolean, message: string) {
  results.push({ test, passed, message })
  const icon = passed ? '✅' : '❌'
  const color = passed ? chalk.green : chalk.red
  console.log(color(`${icon} ${test}: ${message}`))
}

async function testServerOpcodeDecoding(wsUrl: string) {
  console.log(chalk.cyan('🧪 Testing server opcode array decoding...\n'))
  
  return new Promise<void>((resolve, reject) => {
    const ws = new WebSocket(wsUrl)
    let testPhase = 0
    
    ws.onopen = () => {
      console.log(chalk.green('✅ Connected to server\n'))
      
      // Test 1: Send join message (should be JSON format)
      // Extract landType from URL (e.g., ws://localhost:8080/game/counter -> counter)
      const urlParts = wsUrl.split('/')
      const landType = urlParts[urlParts.length - 1] || 'counter'
      
      console.log(chalk.yellow(`Test 1: Send join message (JSON format) for land: ${landType}`))
      const joinMessage = JSON.stringify({
        kind: 'join',
        payload: {
          join: {
            requestID: 'test-join-001',
            landType: landType,
            landInstanceId: null,
            playerID: 'test-player',
            deviceID: 'test-device'
          }
        }
      })
      ws.send(joinMessage)
      console.log(chalk.gray(`   Sent: ${joinMessage.substring(0, 100)}...\n`))
      
      setTimeout(() => {
        // Test 2: Send action in opcode array format (simulating client after receiving encoding)
        console.log(chalk.yellow('Test 2: Send action in opcode array format'))
        const actionArray = [
          101, // opcode for action
          'test-action-001',
          'TestAction',
          Buffer.from(JSON.stringify({ value: 42 })).toString('base64')
        ]
        const actionMessage = JSON.stringify(actionArray)
        ws.send(actionMessage)
        console.log(chalk.gray(`   Sent: ${actionMessage}\n`))
        
        setTimeout(() => {
          // Test 3: Send event in opcode array format
          console.log(chalk.yellow('Test 3: Send event in opcode array format'))
          const eventArray = [
            103, // opcode for event
            0, // direction: fromClient
            'TestEvent',
            { value: 100 }
          ]
          const eventMessage = JSON.stringify(eventArray)
          ws.send(eventMessage)
          console.log(chalk.gray(`   Sent: ${eventMessage}\n`))
          
          setTimeout(() => {
            ws.close()
            resolve()
          }, 1000)
        }, 500)
      }, 500)
    }
    
    ws.onmessage = (event) => {
      const data = event.data
      let message: any
      
      try {
        if (typeof data === 'string') {
          message = JSON.parse(data)
        } else {
          message = JSON.parse(data.toString())
        }
        
        console.log(chalk.cyan(`📥 Received: ${JSON.stringify(message).substring(0, 200)}...`))
        
        // Check if it's an error message
        if (message.kind === 'error' || (message.payload && message.payload.error)) {
          const error = message.payload?.error || message.payload
          logResult(
            `Server response (phase ${testPhase})`,
            false,
            `Server returned error: ${error.code || 'UNKNOWN'} - ${error.message || 'Unknown error'}`
          )
        } else if (message.kind === 'joinResponse') {
          logResult(
            'Join response received',
            true,
            `Success: ${message.payload?.joinResponse?.success || false}, encoding: ${message.payload?.joinResponse?.encoding || 'none'}`
          )
          testPhase = 1
        } else if (message.kind === 'actionResponse') {
          logResult(
            'Action response received',
            true,
            `Action was processed successfully`
          )
          testPhase = 2
        } else {
          logResult(
            `Unexpected message (phase ${testPhase})`,
            false,
            `Received unexpected message kind: ${message.kind}`
          )
        }
      } catch (error) {
        logResult(
          'Message parsing',
          false,
          `Failed to parse message: ${error}`
        )
      }
    }
    
    ws.onerror = (error: any) => {
      const errorMsg = error?.message || error?.toString() || 'Unknown error'
      logResult('Connection', false, `WebSocket error: ${errorMsg}`)
      reject(new Error(errorMsg))
    }
    
    ws.onclose = () => {
      console.log(chalk.gray('\n📊 Test Results Summary:'))
      const passed = results.filter(r => r.passed).length
      const total = results.length
      console.log(chalk.cyan(`   Passed: ${passed}/${total}`))
      
      if (passed === total) {
        console.log(chalk.green('\n✅ All tests passed!'))
        resolve()
      } else {
        console.log(chalk.red('\n❌ Some tests failed'))
        results.filter(r => !r.passed).forEach(r => {
          console.log(chalk.red(`   - ${r.test}: ${r.message}`))
        })
        reject(new Error('Some tests failed'))
      }
    }
  })
}

// Parse command line arguments
const args = process.argv.slice(2)
const urlIndex = args.indexOf('--url')
const wsUrl = urlIndex >= 0 && args[urlIndex + 1] 
  ? args[urlIndex + 1] 
  : 'ws://localhost:8080/game/counter'
console.log(chalk.cyan(`🚀 Testing server opcode decoding at: ${wsUrl}\n`))

testServerOpcodeDecoding(wsUrl)
  .then(() => {
    process.exit(0)
  })
  .catch((error) => {
    console.error(chalk.red(`\n❌ Test failed: ${error}`))
    process.exit(1)
  })
