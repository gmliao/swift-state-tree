#!/usr/bin/env tsx
/**
 * Test script to verify joinResponse contains playerID
 * 
 * This connects to the running GameServer and checks the joinResponse
 */

import WebSocket from 'ws'

const WS_URL = 'ws://localhost:8080/game/hero-defense'

async function testJoinResponse() {
  console.log('🔌 Connecting to server...')
  
  const ws = new WebSocket(WS_URL)
  
  await new Promise<void>((resolve, reject) => {
    ws.on('open', () => {
      console.log('✅ Connected\n')
      resolve()
    })
    ws.on('error', reject)
  })
  
  // Send join request
  const joinRequest = {
    kind: 'join',
    payload: {
      join: {
        requestID: 'test-join-1',
        landType: 'hero-defense',
        landInstanceId: null,
        playerID: 'test-player-123',
        deviceID: 'test-device',
        metadata: {}
      }
    }
  }
  
  console.log('📤 Sending join request:')
  console.log(JSON.stringify(joinRequest, null, 2))
  console.log()
  
  ws.send(JSON.stringify(joinRequest))
  
  // Wait for response
  const response = await new Promise<any>((resolve) => {
    ws.on('message', (data) => {
      const message = JSON.parse(data.toString())
      if (message.kind === 'joinResponse' || (Array.isArray(message) && message[0] === 105)) {
        resolve(message)
      }
    })
  })
  
  console.log('📥 Received joinResponse:')
  console.log(JSON.stringify(response, null, 2))
  console.log()
  
  // Check playerID
  let playerID: string | undefined
  
  if (Array.isArray(response)) {
    // Opcode array format: [105, requestID, success, landType, landInstanceId, playerSlot, encoding, reason]
    // But we need to check if there's a playerID field
    console.log('⚠️  Response is in opcode array format')
    console.log('Array elements:', response)
    console.log()
    
    // Check the structure
    if (response.length >= 6) {
      console.log('Opcode:', response[0])
      console.log('RequestID:', response[1])
      console.log('Success:', response[2])
      console.log('LandType:', response[3])
      console.log('LandInstanceId:', response[4])
      console.log('PlayerSlot:', response[5])
      if (response.length > 6) console.log('Encoding:', response[6])
      if (response.length > 7) console.log('Reason:', response[7])
    }
  } else if (response.kind === 'joinResponse') {
    // Object format
    const payload = response.payload?.joinResponse || response.payload
    playerID = payload.playerID
    
    console.log('✅ Response is in object format')
    console.log('PlayerID:', playerID)
    console.log('PlayerSlot:', payload.playerSlot)
    console.log('LandType:', payload.landType)
    console.log('LandInstanceId:', payload.landInstanceId)
    console.log('Encoding:', payload.encoding)
  }
  
  console.log()
  
  if (playerID) {
    console.log('✅ PlayerID found in response:', playerID)
  } else {
    console.log('❌ PlayerID NOT found in response!')
    console.log('⚠️  This might be why the client doesn\'t know its playerID')
  }
  
  ws.close()
  process.exit(0)
}

testJoinResponse().catch(error => {
  console.error('❌ Test failed:', error)
  process.exit(1)
})
