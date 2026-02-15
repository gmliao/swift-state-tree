#!/usr/bin/env tsx
/**
 * Test script to verify packet encoding/decoding correctness
 * 
 * Tests:
 * 1. encodeMessageArray for joinResponse with encoding field
 * 2. decodeMessage for joinResponse opcode array with encoding field
 * 3. Round-trip encoding/decoding
 */

import { encodeMessageArray, decodeMessage } from '../../../../sdk/ts/src/core/protocol'
import type { TransportMessage } from '../../../../sdk/ts/src/types/transport'

function testJoinResponseEncoding() {
  console.log('🧪 Test 1: encodeMessageArray for joinResponse with encoding')
  
  const message: TransportMessage = {
    kind: 'joinResponse',
    payload: {
      joinResponse: {
        requestID: 'test-req-123',
        success: true,
        landType: 'demo-game',
        landInstanceId: 'instance-1',
        playerSlot: 0,
        encoding: 'opcodeJsonArray',
        reason: undefined
      }
    } as any
  }

  const encoded = encodeMessageArray(message)
  const array = JSON.parse(encoded)
  
  console.log(`   Encoded array: ${JSON.stringify(array)}`)
  
  // Verify structure
  const expected = [105, 'test-req-123', 1, 'demo-game', 'instance-1', 0, 'opcodeJsonArray']
  const matches = JSON.stringify(array) === JSON.stringify(expected)
  
  if (matches) {
    console.log('   ✅ Structure matches expected format')
  } else {
    console.log(`   ❌ Structure mismatch!`)
    console.log(`   Expected: ${JSON.stringify(expected)}`)
    console.log(`   Got:      ${JSON.stringify(array)}`)
    process.exit(1)
  }
  
  // Verify encoding field is at index 6
  if (array[6] === 'opcodeJsonArray') {
    console.log('   ✅ Encoding field correctly placed at index 6')
  } else {
    console.log(`   ❌ Encoding field incorrect! Expected 'opcodeJsonArray' at index 6, got: ${array[6]}`)
    process.exit(1)
  }
}

function testJoinResponseDecoding() {
  console.log('\n🧪 Test 2: decodeMessage for joinResponse opcode array with encoding')
  
  const array = [
    105, // opcode
    'test-req-456',
    1, // success
    'demo-game',
    'instance-2',
    1, // playerSlot
    'opcodeJsonArray', // encoding
    null // reason
  ]

  const encoded = JSON.stringify(array)
  const decoded = decodeMessage(encoded) as TransportMessage

  console.log(`   Decoded message kind: ${decoded.kind}`)
  
  if (decoded.kind !== 'joinResponse') {
    console.log(`   ❌ Expected 'joinResponse', got: ${decoded.kind}`)
    process.exit(1)
  }
  
  const payload = (decoded.payload as any).joinResponse
  console.log(`   Payload: ${JSON.stringify(payload, null, 2)}`)
  
  // Verify fields
  if (payload.requestID !== 'test-req-456') {
    console.log(`   ❌ requestID mismatch! Expected 'test-req-456', got: ${payload.requestID}`)
    process.exit(1)
  }
  
  if (payload.success !== true) {
    console.log(`   ❌ success mismatch! Expected true, got: ${payload.success}`)
    process.exit(1)
  }
  
  if (payload.encoding !== 'opcodeJsonArray') {
    console.log(`   ❌ encoding mismatch! Expected 'opcodeJsonArray', got: ${payload.encoding}`)
    process.exit(1)
  }
  
  console.log('   ✅ All fields decoded correctly')
  console.log(`   ✅ Encoding field: ${payload.encoding}`)
}

function testJoinResponseWithoutEncoding() {
  console.log('\n🧪 Test 3: joinResponse without encoding field')
  
  const message: TransportMessage = {
    kind: 'joinResponse',
    payload: {
      joinResponse: {
        requestID: 'test-req-789',
        success: false,
        reason: 'Room full'
      }
    } as any
  }

  const encoded = encodeMessageArray(message)
  const array = JSON.parse(encoded)
  
  console.log(`   Encoded array: ${JSON.stringify(array)}`)
  
  // Verify encoding is null when not provided
  if (array[6] === null) {
    console.log('   ✅ Encoding field is null when not provided')
  } else {
    console.log(`   ❌ Expected encoding to be null, got: ${array[6]}`)
    process.exit(1)
  }
  
  // Decode and verify
  const decoded = decodeMessage(encoded) as TransportMessage
  const payload = (decoded.payload as any).joinResponse
  
  if (payload.encoding === undefined) {
    console.log('   ✅ Encoding field is undefined after decoding when not provided')
  } else {
    console.log(`   ❌ Expected encoding to be undefined, got: ${payload.encoding}`)
    process.exit(1)
  }
}

function testRoundTrip() {
  console.log('\n🧪 Test 4: Round-trip encoding/decoding')
  
  const original: TransportMessage = {
    kind: 'joinResponse',
    payload: {
      joinResponse: {
        requestID: 'roundtrip-123',
        success: true,
        landType: 'test-land',
        landInstanceId: 'test-instance',
        playerSlot: 2,
        encoding: 'opcodeJsonArray',
        reason: undefined
      }
    } as any
  }

  // Encode
  const encoded = encodeMessageArray(original)
  console.log(`   Encoded: ${encoded}`)
  
  // Decode
  const decoded = decodeMessage(encoded) as TransportMessage
  const payload = (decoded.payload as any).joinResponse
  
  // Verify all fields match
  const fields = ['requestID', 'success', 'landType', 'landInstanceId', 'playerSlot', 'encoding']
  let allMatch = true
  
  for (const field of fields) {
    if (original.payload.joinResponse[field] !== payload[field]) {
      console.log(`   ❌ Field ${field} mismatch!`)
      console.log(`      Original: ${original.payload.joinResponse[field]}`)
      console.log(`      Decoded:  ${payload[field]}`)
      allMatch = false
    }
  }
  
  if (allMatch) {
    console.log('   ✅ All fields match after round-trip')
  } else {
    process.exit(1)
  }
}

function testActionEncoding() {
  console.log('\n🧪 Test 5: Action encoding with opcode array format')
  
  const message: TransportMessage = {
    kind: 'action',
    payload: {
      requestID: 'action-req-123',
      typeIdentifier: 'TestAction',
      payload: 'dGVzdC1wYXlsb2Fk' // base64 encoded "test-payload"
    } as any
  }

  const encoded = encodeMessageArray(message)
  const array = JSON.parse(encoded)
  
  console.log(`   Encoded array: ${JSON.stringify(array)}`)
  
  // Verify structure: [101, requestID, typeIdentifier, payload]
  if (array[0] === 101 && array[1] === 'action-req-123' && array[2] === 'TestAction' && array[3] === 'dGVzdC1wYXlsb2Fk') {
    console.log('   ✅ Action encoded correctly')
  } else {
    console.log(`   ❌ Action encoding incorrect!`)
    console.log(`   Expected: [101, 'action-req-123', 'TestAction', 'dGVzdC1wYXlsb2Fk']`)
    console.log(`   Got:      ${JSON.stringify(array)}`)
    process.exit(1)
  }
}

function testEventEncoding() {
  console.log('\n🧪 Test 6: Event encoding with opcode array format')
  
  const message: TransportMessage = {
    kind: 'event',
    payload: {
      fromClient: {
        type: 'TestEvent',
        payload: { value: 42 }
      }
    } as any
  }

  const encoded = encodeMessageArray(message)
  const array = JSON.parse(encoded)
  
  console.log(`   Encoded array: ${JSON.stringify(array)}`)
  
  // Verify structure: [103, direction(0=client), type, payload]
  if (array[0] === 103 && array[1] === 0 && array[2] === 'TestEvent') {
    console.log('   ✅ Event encoded correctly')
    console.log(`   Direction: ${array[1] === 0 ? 'fromClient' : 'fromServer'}`)
    console.log(`   Type: ${array[2]}`)
    console.log(`   Payload: ${JSON.stringify(array[3])}`)
  } else {
    console.log(`   ❌ Event encoding incorrect!`)
    console.log(`   Got: ${JSON.stringify(array)}`)
    process.exit(1)
  }
}

// Run all tests
console.log('🚀 Starting packet encoding/decoding tests...\n')

try {
  testJoinResponseEncoding()
  testJoinResponseDecoding()
  testJoinResponseWithoutEncoding()
  testRoundTrip()
  testActionEncoding()
  testEventEncoding()
  
  console.log('\n✅ All tests passed!')
  process.exit(0)
} catch (error) {
  console.error('\n❌ Test failed:', error)
  process.exit(1)
}
