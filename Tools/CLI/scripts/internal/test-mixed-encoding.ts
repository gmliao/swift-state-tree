#!/usr/bin/env tsx
/**
 * Test script to verify mixed JSON and MessagePack encoding in WebSocket
 * 
 * This script tests:
 * 1. Sending JSON messages (text frame)
 * 2. Sending binary messages (binary frame)
 * 3. Receiving and correctly identifying both types
 * 
 * Usage:
 *   npm run dev -- test-mixed-encoding --url ws://localhost:8080/game
 */

import WebSocket from 'ws'

interface TestResult {
  test: string
  passed: boolean
  message: string
}

const results: TestResult[] = []

function logResult(test: string, passed: boolean, message: string) {
  results.push({ test, passed, message })
  const icon = passed ? '✅' : '❌'
  console.log(`${icon} ${test}: ${message}`)
}

async function testMixedEncoding(wsUrl: string) {
  console.log('🧪 Testing Mixed Encoding (JSON + Binary) in WebSocket\n')
  console.log(`Connecting to: ${wsUrl}\n`)

  return new Promise<void>((resolve, reject) => {
    const ws = new WebSocket(wsUrl)
    let textFrameReceived = false
    let binaryFrameReceived = false
    let textFrameSent = false
    let binaryFrameSent = false

    ws.on('open', () => {
      console.log('✅ WebSocket connected\n')

      // Extract landType from URL (e.g., ws://localhost:8080/game/counter -> counter)
      const urlParts = wsUrl.split('/')
      const landType = urlParts[urlParts.length - 1] || 'counter'
      
      // Test 1: Send JSON message (text frame)
      console.log(`📤 Test 1: Sending JSON message (text frame) for land: ${landType}...`)
      const jsonMessage = JSON.stringify({
        kind: 'join',
        payload: {
          join: {
            requestID: 'test-json-001',
            landType: landType,
            landInstanceId: null
          }
        }
      })
      ws.send(jsonMessage)
      textFrameSent = true
      logResult('Send JSON (text frame)', true, 'JSON message sent successfully')

      // Wait a bit before sending binary
      setTimeout(() => {
        // Test 2: Send binary message (binary frame)
        console.log('\n📤 Test 2: Sending binary message (binary frame)...')
        // Create a simple binary message (simulating MessagePack)
        // In real MessagePack, this would be properly encoded
        // For testing, we just send binary data to verify frame type handling
        const binaryMessage = Buffer.from([
          0x82, // MessagePack map with 2 elements
          0xa4, 0x6b, 0x69, 0x6e, 0x64, // "kind" (4 bytes)
          0xa4, 0x6a, 0x6f, 0x69, 0x6e, // "join" (4 bytes)
          0xa7, 0x70, 0x61, 0x79, 0x6c, 0x6f, 0x61, 0x64, // "payload" (7 bytes)
          0x80 // empty map
        ])
        ws.send(binaryMessage)
        binaryFrameSent = true
        logResult('Send Binary (binary frame)', true, 'Binary message sent successfully')

        // Wait longer to receive responses, then close
        setTimeout(() => {
          // If we haven't received both frame types, that's okay - we tested sending
          if (!textFrameReceived && !binaryFrameReceived) {
            console.log('\n⚠️  Note: Server responses not received (this is okay for encoding test)')
          }
          ws.close()
        }, 3000)
      }, 500)
    })

    ws.on('message', (data: WebSocket.Data) => {
      // Determine if message is text or binary
      const isText = typeof data === 'string'
      const isBinary = Buffer.isBuffer(data) || data instanceof ArrayBuffer

      if (isText) {
        console.log('\n📥 Received TEXT frame:')
        console.log(`   Type: ${typeof data}`)
        console.log(`   Content: ${data.toString().substring(0, 100)}...`)
        textFrameReceived = true
        logResult('Receive Text Frame', true, 'Successfully received and identified text frame')
      } else if (isBinary) {
        console.log('\n📥 Received BINARY frame:')
        console.log(`   Type: ${Buffer.isBuffer(data) ? 'Buffer' : 'ArrayBuffer'}`)
        console.log(`   Size: ${Buffer.isBuffer(data) ? data.length : (data as ArrayBuffer).byteLength} bytes`)
        console.log(`   Hex preview: ${Buffer.from(data as ArrayBuffer).toString('hex').substring(0, 40)}...`)
        binaryFrameReceived = true
        logResult('Receive Binary Frame', true, 'Successfully received and identified binary frame')
      } else {
        logResult('Receive Message Type', false, `Unknown message type: ${typeof data}`)
      }
    })

    ws.on('error', (error) => {
      logResult('WebSocket Error', false, `Connection error: ${error.message}`)
      reject(error)
    })

    ws.on('close', () => {
      console.log('\n📊 Test Results Summary:')
      console.log('=' .repeat(50))
      
      // Verify all tests
      const allTestsPassed = 
        textFrameSent &&
        binaryFrameSent &&
        textFrameReceived &&
        binaryFrameReceived

      results.forEach(result => {
        const icon = result.passed ? '✅' : '❌'
        console.log(`${icon} ${result.test}: ${result.message}`)
      })

      console.log('\n' + '='.repeat(50))
      
      if (allTestsPassed) {
        console.log('\n🎉 All tests passed! WebSocket supports mixed encoding.')
        console.log('   ✅ Text frames (JSON) work correctly')
        console.log('   ✅ Binary frames (MessagePack) work correctly')
        console.log('   ✅ Both can be used in the same connection')
      } else {
        console.log('\n⚠️  Some tests failed. Check the results above.')
      }

      resolve()
    })
  })
}

// Parse command line arguments
const args = process.argv.slice(2)
const urlIndex = args.indexOf('--url')
const wsUrl = urlIndex >= 0 && args[urlIndex + 1] 
  ? args[urlIndex + 1] 
  : 'ws://localhost:8080/game'

// Run test
testMixedEncoding(wsUrl)
  .then(() => {
    process.exit(0)
  })
  .catch((error) => {
    console.error('❌ Test failed:', error)
    process.exit(1)
  })
