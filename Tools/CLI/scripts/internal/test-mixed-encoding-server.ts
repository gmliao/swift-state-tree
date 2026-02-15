#!/usr/bin/env tsx
/**
 * Simple WebSocket echo server for testing mixed encoding
 * 
 * This server echoes back messages, preserving their frame type (text or binary)
 * 
 * Usage:
 *   npm run test-mixed-encoding-server
 * 
 * Then in another terminal:
 *   npm run test-mixed-encoding -- --url ws://localhost:8081
 */

import WebSocket from 'ws'

const PORT = 8081
const wss = new WebSocket.Server({ port: PORT })

console.log(`🚀 WebSocket test server started on ws://localhost:${PORT}`)
console.log('   This server echoes messages back, preserving frame type\n')

wss.on('connection', (ws) => {
  console.log('✅ Client connected')

  ws.on('message', (data: WebSocket.Data, isBinary: boolean) => {
    const frameType = isBinary ? 'BINARY' : 'TEXT'
    const size = Buffer.isBuffer(data) ? data.length : (data as string).length
    
    console.log(`📥 Received ${frameType} frame (${size} bytes)`)

    // Echo back the message, preserving frame type
    if (isBinary) {
      // Binary frame - send as binary
      ws.send(data as Buffer)
      console.log(`📤 Echoed back as BINARY frame`)
    } else {
      // Text frame - send as text
      ws.send(data as string)
      console.log(`📤 Echoed back as TEXT frame`)
    }
  })

  ws.on('close', () => {
    console.log('❌ Client disconnected\n')
  })

  ws.on('error', (error) => {
    console.error('❌ WebSocket error:', error)
  })
})

console.log('Press Ctrl+C to stop the server\n')
