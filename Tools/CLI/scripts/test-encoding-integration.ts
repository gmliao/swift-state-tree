#!/usr/bin/env tsx
/**
 * Integration test to verify encoding field works end-to-end
 * 
 * This script tests:
 * 1. Client sends join (JSON format)
 * 2. Server responds with joinResponse (with encoding field)
 * 3. Client receives and updates encoding
 * 4. Client sends action/event using the specified encoding
 */

import { StateTreeRuntime, StateTreeView } from '../../../sdk/ts/src/core/runtime'
import { createWebSocket } from '../../../sdk/ts/src/core/websocket'
import type { TransportMessage } from '../../../sdk/ts/src/types/transport'

// Mock WebSocket for testing
class MockWebSocket {
  private onMessageCallback?: (data: string | ArrayBuffer) => void
  private sentMessages: (string | ArrayBuffer)[] = []
  
  send(data: string | ArrayBuffer) {
    this.sentMessages.push(data)
    console.log(`📤 Sent: ${typeof data === 'string' ? data : `[Binary ${data.byteLength} bytes]`}`)
  }
  
  set onmessage(callback: (event: { data: string | ArrayBuffer }) => void) {
    this.onMessageCallback = callback
  }
  
  simulateMessage(data: string | ArrayBuffer) {
    if (this.onMessageCallback) {
      this.onMessageCallback({ data })
    }
  }
  
  getSentMessages() {
    return this.sentMessages
  }
  
  close() {
    // Mock close
  }
}

// Test encoding field propagation
async function testEncodingPropagation() {
  console.log('🧪 Testing encoding field propagation...\n')
  
  const mockWs = new MockWebSocket() as any
  
  // Create runtime with mock WebSocket
  const runtime = new StateTreeRuntime({
    logger: {
      info: () => {},
      error: () => {},
      warn: () => {},
      debug: () => {}
    }
  })
  
  // Inject mock WebSocket
  ;(runtime as any).ws = mockWs
  ;(runtime as any).isConnected = true
  
  // Create a simple view
  const view = (runtime as any).createView('test-land', {
    schema: { schemaHash: 'test' }
  }) as StateTreeView
  
  // Simulate join request (should be JSON)
  console.log('1️⃣  Client sends join request...')
  await view.join()
  
  const joinMessage = mockWs.getSentMessages()[0] as string
  const joinParsed = JSON.parse(joinMessage)
  
  if (joinParsed.kind === 'join') {
    console.log('   ✅ Join message is in JSON format')
  } else {
    console.log('   ❌ Join message format incorrect!')
    process.exit(1)
  }
  
  // Simulate server joinResponse with encoding
  console.log('\n2️⃣  Server responds with joinResponse (opcode array with encoding)...')
  const joinResponseArray = [
    105, // opcode
    joinParsed.payload.join.requestID,
    1, // success
    'test-land',
    'instance-1',
    0, // playerSlot
    'opcodeJsonArray', // encoding
    null // reason
  ]
  
  const joinResponseEncoded = JSON.stringify(joinResponseArray)
  console.log(`   Response: ${joinResponseEncoded}`)
  
  // Simulate receiving the message
  mockWs.simulateMessage(joinResponseEncoded)
  
  // Check if view updated encoding
  const viewEncoding = (view as any).messageEncoding
  console.log(`\n3️⃣  View encoding after joinResponse: ${viewEncoding}`)
  
  if (viewEncoding === 'opcodeJsonArray') {
    console.log('   ✅ View encoding updated correctly')
  } else {
    console.log(`   ❌ Expected 'opcodeJsonArray', got: ${viewEncoding}`)
    process.exit(1)
  }
  
  // Send an action (should use opcode array format)
  console.log('\n4️⃣  Client sends action (should use opcodeJsonArray)...')
  mockWs.getSentMessages().length = 0 // Clear previous messages
  
  try {
    await view.sendAction('TestAction', { value: 42 })
  } catch (e) {
    // Expected to fail without actual server, but we can check the message format
  }
  
  const actionMessage = mockWs.getSentMessages()[0] as string
  console.log(`   Action message: ${actionMessage.substring(0, 100)}...`)
  
  // Check if it's opcode array format
  try {
    const actionArray = JSON.parse(actionMessage)
    if (Array.isArray(actionArray) && actionArray[0] === 101) {
      console.log('   ✅ Action sent in opcode array format')
      console.log(`   Array: ${JSON.stringify(actionArray)}`)
    } else {
      console.log('   ❌ Action not in opcode array format!')
      console.log(`   Got: ${JSON.stringify(actionArray).substring(0, 200)}`)
      process.exit(1)
    }
  } catch (e) {
    console.log('   ❌ Failed to parse action message as JSON array')
    process.exit(1)
  }
  
  console.log('\n✅ All integration tests passed!')
}

// Run test
testEncodingPropagation().catch(error => {
  console.error('❌ Test failed:', error)
  process.exit(1)
})
