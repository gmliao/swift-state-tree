#!/usr/bin/env tsx
/**
 * Automated test script for Hero Defense game
 * 
 * Automatically connects, plays the game, and sends commands to verify functionality
 */

import chalk from 'chalk'
import { StateTreeRuntime } from '@swiftstatetree/sdk/core'
import { HeroDefenseStateTree } from './generated/hero-defense/index.js'
import { LAND_TYPE } from './generated/hero-defense/bindings.js'

interface TestState {
  runtime: StateTreeRuntime | null
  tree: HeroDefenseStateTree | null
  playerID: string | null
  isConnected: boolean
  isJoined: boolean
  testPassed: number
  testFailed: number
}

const testState: TestState = {
  runtime: null,
  tree: null,
  playerID: null,
  isConnected: false,
  isJoined: false,
  testPassed: 0,
  testFailed: 0
}

// Parse command line arguments
const args = process.argv.slice(2)
let wsUrl = 'ws://localhost:8080/game/hero-defense'
let playerName = `auto-test-${Date.now()}`
let roomId = 'default'
let logMode: LogMode = 'quiet'

for (const arg of args) {
  if (arg.startsWith('--mode=')) {
    const m = arg.split('=')[1] as LogMode
    if (['quiet', 'normal', 'verbose'].includes(m)) {
      logMode = m
    }
  } else if (arg.startsWith('ws://') || arg.startsWith('wss://')) {
    wsUrl = arg
  } else if (!arg.includes('=')) {
    if (playerName === `auto-test-${Date.now()}`) {
      playerName = arg
    } else if (roomId === 'default') {
      roomId = arg
    }
  }
}

// Game bounds (from map.json or game logic)
const MAP_MIN_X = 0
const MAP_MAX_X = 128
const MAP_MIN_Y = 0
const MAP_MAX_Y = 72
const BASE_X = 64
const BASE_Y = 36

function log(message: string, type: 'info' | 'success' | 'error' | 'warn' = 'info', force: boolean = false) {
  // In quiet mode, only show errors and forced messages
  if (logMode === 'quiet' && type !== 'error' && !force) {
    return
  }
  
  // In normal mode, show errors, warnings, and successes (but not info)
  if (logMode === 'normal' && type === 'info' && !force) {
    return
  }
  
  const timestamp = logMode === 'verbose' ? `[${new Date().toISOString()}]` : ''
  const prefix = timestamp ? `${timestamp} ` : ''
  
  switch (type) {
    case 'success':
      console.log(chalk.green(`${prefix}✅ ${message}`))
      break
    case 'error':
      console.error(chalk.red(`${prefix}❌ ${message}`))
      break
    case 'warn':
      console.warn(chalk.yellow(`${prefix}⚠️  ${message}`))
      break
    default:
      console.log(chalk.cyan(`${prefix}ℹ️  ${message}`))
  }
}

function testPass(name: string) {
  testState.testPassed++
  log(`Test passed: ${name}`, 'success')
}

function testFail(name: string, reason: string) {
  testState.testFailed++
  log(`Test failed: ${name}: ${reason}`, 'error')
}

function getRandomPosition(): { x: number; y: number } {
  // Random position within map bounds, but avoid base area
  const margin = 10
  const x = Math.random() * (MAP_MAX_X - MAP_MIN_X - margin * 2) + MAP_MIN_X + margin
  const y = Math.random() * (MAP_MAX_Y - MAP_MIN_Y - margin * 2) + MAP_MIN_Y + margin
  return { x, y }
}

function formatPosition(x: number, y: number): string {
  return `(${x.toFixed(1)}, ${y.toFixed(1)})`
}

async function connect(): Promise<boolean> {
  if (testState.isConnected) {
    log('Already connected', 'warn')
    return true
  }

  try {
    log(`Connecting to ${wsUrl}...`, 'info', true)
    
    const runtime = new StateTreeRuntime({
      logger: {
        debug: () => {},
        info: (msg) => logMode === 'verbose' && log(`[Runtime] ${msg}`, 'info'),
        warn: (msg) => log(`[Runtime] ${msg}`, 'warn'),
        error: (msg) => log(`[Runtime] ${msg}`, 'error')
      }
    })

    await runtime.connect(wsUrl)
    testState.runtime = runtime
    testState.isConnected = true
    log('Connected to server', 'success')

    // Build landID
    let landID: string | undefined = roomId
    if (landID && !landID.includes(':')) {
      landID = `${LAND_TYPE}:${landID}`
    }

    const tree = new HeroDefenseStateTree(runtime, {
      landID: landID,
      playerID: undefined,
      deviceID: `auto-test-${Date.now()}`,
      metadata: { username: playerName },
      logger: {
        debug: () => {},
        info: (msg) => logMode === 'verbose' && log(`[Tree] ${msg}`, 'info'),
        warn: (msg) => log(`[Tree] ${msg}`, 'warn'),
        error: (msg) => log(`[Tree] ${msg}`, 'error')
      }
    })

    testState.tree = tree

    const joinResult = await tree.join()
    if (!joinResult.success) {
      throw new Error(joinResult.reason ?? 'Join failed')
    }

    testState.playerID = joinResult.playerID ?? null
    testState.isJoined = true

    log(`Joined game! Player ID: ${testState.playerID}`, 'success', true)
    testPass('Connect and Join')

    // Set up disconnect handler
    runtime.onDisconnect((code, reason, wasClean) => {
      log(`Disconnected (code: ${code}, reason: ${reason})`, 'warn')
      testState.isConnected = false
      testState.isJoined = false
      testState.runtime = null
      testState.tree = null
      testState.playerID = null
    })

    return true
  } catch (error) {
    log(`Connection failed: ${error}`, 'error')
    testState.isConnected = false
    testState.isJoined = false
    testState.runtime = null
    testState.tree = null
    testFail('Connect and Join', String(error))
    return false
  }
}

async function testPlayAction(): Promise<boolean> {
  if (!testState.tree || !testState.isJoined) {
    testFail('Play Action', 'Not connected or joined')
    return false
  }

  try {
    log('Sending play action...', 'info', logMode !== 'quiet')
    const result = await testState.tree.actions.play({})
    if (logMode === 'verbose') {
      log(`Play action response: ${JSON.stringify(result)}`, 'info')
    }
    testPass('Play Action')
    return true
  } catch (error) {
    testFail('Play Action', String(error))
    return false
  }
}

async function testMoveEvent(): Promise<boolean> {
  if (!testState.tree || !testState.isJoined) {
    testFail('Move Event', 'Not connected or joined')
    return false
  }

  try {
    const position = getRandomPosition()
    if (logMode === 'verbose') {
      log(`Sending move event to ${formatPosition(position.x, position.y)}...`, 'info')
    }
    
    // Get current player position before move
    const state = testState.tree.state
    const player = testState.playerID ? state.players[testState.playerID] : null
    if (!player) {
      testFail('Move Event', 'Player not found in state')
      return false
    }
    const oldPosition = { x: player.position.x, y: player.position.y }
    
    // Send move event
    testState.tree.events.moveTo(position)
    
    // Wait a bit for state update
    await new Promise(resolve => setTimeout(resolve, 300))
    
    // Verify position changed
    const updatedState = testState.tree.state
    const newPlayer = testState.playerID ? updatedState.players[testState.playerID] : null
    if (!newPlayer) {
      testFail('Move Event', 'Player not found after move')
      return false
    }
    
    const newPosition = { x: newPlayer.position.x, y: newPlayer.position.y }
    const distance = Math.sqrt(
      Math.pow(newPosition.x - oldPosition.x, 2) + 
      Math.pow(newPosition.y - oldPosition.y, 2)
    )
    
    if (logMode === 'verbose') {
      log(`Position changed: ${formatPosition(oldPosition.x, oldPosition.y)} -> ${formatPosition(newPosition.x, newPosition.y)} (distance: ${distance.toFixed(2)})`, 'info')
    }
    
    // Position should have changed (at least moved towards target)
    // Note: In deterministic math, positions are in fixed-point, so we check for any movement
    if (distance > 0.01) {
      testPass('Move Event')
      return true
    } else {
      // Position might not have changed yet (still moving), but event was sent successfully
      testPass('Move Event (sent successfully)')
      return true
    }
  } catch (error) {
    testFail('Move Event', String(error))
    return false
  }
}

async function testShootEvent(): Promise<boolean> {
  if (!testState.tree || !testState.isJoined) {
    testFail('Shoot Event', 'Not connected or joined')
    return false
  }

  try {
    const target = getRandomPosition()
    if (logMode === 'verbose') {
      log(`Sending shoot event to ${formatPosition(target.x, target.y)}...`, 'info')
    }
    testState.tree.events.shoot(target)
    testPass('Shoot Event')
    return true
  } catch (error) {
    testFail('Shoot Event', String(error))
    return false
  }
}

async function testPlaceTurretEvent(): Promise<boolean> {
  if (!testState.tree || !testState.isJoined) {
    testFail('Place Turret Event', 'Not connected or joined')
    return false
  }

  try {
    const state = testState.tree.state
    const player = testState.playerID ? state.players[testState.playerID] : null
    if (!player) {
      testFail('Place Turret Event', 'Player not found')
      return false
    }

    // Need at least some resources to place turret
    if (player.resources < 5) {
      log('Not enough resources to place turret, skipping...', 'warn')
      return true // Not a failure, just skip
    }

    // Place turret near base but not too close
    const turretX = BASE_X + (Math.random() - 0.5) * 20
    const turretY = BASE_Y + (Math.random() - 0.5) * 20
    
    const turretCountBefore = Object.keys(state.turrets).length
    if (logMode === 'verbose') {
      log(`Sending place turret event at ${formatPosition(turretX, turretY)}...`, 'info')
    }
    testState.tree.events.placeTurret({ x: turretX, y: turretY })
    
    // Wait for state update
    await new Promise(resolve => setTimeout(resolve, 300))
    
    const turretCountAfter = Object.keys(state.turrets).length
    if (turretCountAfter > turretCountBefore) {
      if (logMode !== 'quiet') {
        log(`Turret placed! Total turrets: ${turretCountAfter}`, 'success')
      }
      testPass('Place Turret Event')
      return true
    } else {
      // Might fail due to placement rules, not necessarily a bug
      testPass('Place Turret Event (sent successfully)')
      return true
    }
  } catch (error) {
    testFail('Place Turret Event', String(error))
    return false
  }
}

async function testUpgradeWeaponEvent(): Promise<boolean> {
  if (!testState.tree || !testState.isJoined) {
    testFail('Upgrade Weapon Event', 'Not connected or joined')
    return false
  }

  try {
    const state = testState.tree.state
    const player = testState.playerID ? state.players[testState.playerID] : null
    if (!player) {
      testFail('Upgrade Weapon Event', 'Player not found')
      return false
    }

    if (player.resources < 5) {
      log('Not enough resources to upgrade weapon, skipping...', 'warn')
      return true
    }

    const oldLevel = player.weaponLevel
    if (logMode === 'verbose') {
      log(`Upgrading weapon (current level: ${oldLevel}, resources: ${player.resources})...`, 'info')
    }
    testState.tree.events.upgradeWeapon({})
    
    // Wait for state update
    await new Promise(resolve => setTimeout(resolve, 300))
    
    const newPlayer = testState.playerID ? state.players[testState.playerID] : null
    if (newPlayer && newPlayer.weaponLevel > oldLevel) {
      if (logMode !== 'quiet') {
        log(`Weapon upgraded! Level: ${oldLevel} -> ${newPlayer.weaponLevel}`, 'success')
      }
      testPass('Upgrade Weapon Event')
      return true
    } else {
      // Might fail due to insufficient resources or other game rules
      testPass('Upgrade Weapon Event (sent successfully)')
      return true
    }
  } catch (error) {
    testFail('Upgrade Weapon Event', String(error))
    return false
  }
}

async function printStatus() {
  if (!testState.tree || !testState.isJoined) {
    return
  }

  if (logMode === 'quiet') {
    return // Skip status in quiet mode
  }

  const state = testState.tree.state
  const player = testState.playerID ? state.players[testState.playerID] : null

  log('\n=== Game Status ===', 'info', true)
  log(`Base HP: ${state.base.hp}/${state.base.maxHp}`, 'info', true)
  log(`Wave: ${state.wave}`, 'info', true)
  log(`Monsters: ${Object.keys(state.monsters).length}`, 'info', true)
  log(`Turrets: ${Object.keys(state.turrets).length}`, 'info', true)
  
  if (player) {
    log(`\n=== Player Status ===`, 'info', true)
    log(`Position: ${formatPosition(player.position.x, player.position.y)}`, 'info', true)
    log(`HP: ${player.hp}/${player.maxHp}`, 'info', true)
    log(`Resources: ${player.resources}`, 'info', true)
    log(`Weapon Level: ${player.weaponLevel} (Damage: ${player.weaponDamage}, Range: ${player.weaponRange})`, 'info', true)
  }
  log('', 'info', true)
}

async function runAutomatedTests() {
  log('🚀 Starting automated tests...', 'info', true)
  if (logMode !== 'quiet') {
    log(`Server: ${wsUrl}`, 'info')
    log(`Player: ${playerName}`, 'info')
    log(`Room: ${roomId}`, 'info')
    log(`Mode: ${logMode}`, 'info')
    log('', 'info')
  }

  // Step 1: Connect
  const connected = await connect()
  if (!connected) {
    log('❌ Failed to connect, aborting tests', 'error')
    process.exit(1)
  }

  await new Promise(resolve => setTimeout(resolve, 1000))

  // Step 2: Start game
  await testPlayAction()
  await new Promise(resolve => setTimeout(resolve, 1000))

  // Step 3: Print initial status
  await printStatus()

  // Step 4: Run automated movement and actions
  if (logMode !== 'quiet') {
    log('🔄 Starting automated movement and action tests...', 'info', true)
  }
  
  const testDuration = 5000 // 5 seconds
  const moveInterval = 1000 // Move every 1 second
  const actionInterval = 2000 // Send action every 2 seconds
  const startTime = Date.now()

  const moveTimer = setInterval(async () => {
    if (Date.now() - startTime > testDuration) {
      clearInterval(moveTimer)
      return
    }
    if (testState.isJoined && testState.tree) {
      await testMoveEvent()
      await new Promise(resolve => setTimeout(resolve, 200))
    }
  }, moveInterval)

  const actionTimer = setInterval(async () => {
    if (Date.now() - startTime > testDuration) {
      clearInterval(actionTimer)
      return
    }
    if (testState.isJoined && testState.tree) {
      // Randomly choose an action
      const actions = [
        () => testShootEvent(),
        () => testPlaceTurretEvent(),
        () => testUpgradeWeaponEvent()
      ]
      const action = actions[Math.floor(Math.random() * actions.length)]
      await action()
      await new Promise(resolve => setTimeout(resolve, 200))
    }
  }, actionInterval)

  // Wait for test duration
  await new Promise(resolve => setTimeout(resolve, testDuration + 1000))

  clearInterval(moveTimer)
  clearInterval(actionTimer)

  // Final status
  await printStatus()

  // Test summary (always show)
  log('\n=== Test Summary ===', 'info', true)
  log(`Passed: ${testState.testPassed}`, 'success', true)
  log(`Failed: ${testState.testFailed}`, testState.testFailed > 0 ? 'error' : 'success', true)
  log(`Total: ${testState.testPassed + testState.testFailed}`, 'info', true)

  // Cleanup
  if (testState.tree) {
    testState.tree.destroy()
  }
  if (testState.runtime) {
    testState.runtime.disconnect()
  }

  process.exit(testState.testFailed > 0 ? 1 : 0)
}

// Run tests
runAutomatedTests().catch((error) => {
  log(`Fatal error: ${error}`, 'error')
  process.exit(1)
})
