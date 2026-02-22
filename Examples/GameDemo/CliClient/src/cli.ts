#!/usr/bin/env tsx
/**
 * Hero Defense CLI Client
 * 
 * A command-line interface for playing the Hero Defense game
 * Uses the same SDK logic as the WebClient
 */

import readline from 'readline'
import chalk from 'chalk'
import { StateTreeRuntime, Position2 } from '@swiftstatetree/sdk/core'
import { HeroDefenseStateTree } from './generated/hero-defense/index.js'
import { LAND_TYPE } from './generated/hero-defense/bindings.js'
import type { HeroDefenseState, PlayerState, MonsterState, TurretState } from './generated/defs.js'

interface GameState {
  runtime: StateTreeRuntime | null
  tree: HeroDefenseStateTree | null
  playerID: string | null
  isConnected: boolean
  isJoined: boolean
}

const gameState: GameState = {
  runtime: null,
  tree: null,
  playerID: null,
  isConnected: false,
  isJoined: false
}

const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout,
  prompt: chalk.cyan('> ')
})

// Parse command line arguments
const args = process.argv.slice(2)
const wsUrl = args[0] || 'ws://localhost:8080/game/hero-defense'
const playerName = args[1] || `player-${Math.floor(Math.random() * 10000)}`
const roomId = args[2] || 'default'

function printHelp() {
  console.log(chalk.yellow('\n可用指令:'))
  console.log('  help              - 顯示此幫助訊息')
  console.log('  connect           - 連接到遊戲伺服器')
  console.log('  disconnect        - 斷開連接')
  console.log('  play              - 開始遊戲')
  console.log('  move <x> <y>      - 移動玩家到指定位置')
  console.log('  shoot <x> <y>     - 向指定位置射擊')
  console.log('  place <x> <y>     - 在指定位置放置炮塔')
  console.log('  upgrade-weapon    - 升級武器 (消耗 5 資源)')
  console.log('  upgrade-turret <id> - 升級指定炮塔 (消耗 10 資源)')
  console.log('  status            - 顯示遊戲狀態')
  console.log('  players           - 顯示所有玩家')
  console.log('  monsters          - 顯示所有怪物')
  console.log('  turrets           - 顯示所有炮塔')
  console.log('  quit              - 退出程式\n')
}

function formatPosition(x: number, y: number): string {
  return `(${x.toFixed(1)}, ${y.toFixed(1)})`
}

function printStatus() {
  if (!gameState.tree || !gameState.isJoined) {
    console.log(chalk.red('尚未連接或加入遊戲'))
    return
  }

  const state = gameState.tree.state
  const player = gameState.playerID ? state.players[gameState.playerID] : null

  console.log(chalk.cyan('\n=== 遊戲狀態 ==='))
  console.log(`基地生命值: ${chalk.red(state.base.health)}/${chalk.green(state.base.maxHealth)}`)
  console.log(`分數: ${chalk.yellow(state.score)}`)
  console.log(`怪物數量: ${chalk.red(Object.keys(state.monsters).length)}`)
  console.log(`炮塔數量: ${chalk.blue(Object.keys(state.turrets).length)}`)
  
  if (player) {
    console.log(chalk.green(`\n=== 玩家狀態 (${playerName}) ===`))
    console.log(`位置: ${formatPosition(player.position.v.x, player.position.v.y)}`)
    console.log(`生命值: ${player.health}/${player.maxHealth}`)
    console.log(`資源: ${chalk.yellow(player.resources)}`)
    console.log(`武器等級: ${player.weaponLevel}`)
  }
  
  console.log('')
}

function printPlayers() {
  if (!gameState.tree || !gameState.isJoined) {
    console.log(chalk.red('尚未連接或加入遊戲'))
    return
  }

  const players = gameState.tree.state.players
  console.log(chalk.cyan('\n=== 玩家列表 ==='))
  for (const [id, player] of Object.entries(players)) {
    const isMe = id === gameState.playerID
    const prefix = isMe ? chalk.green('* ') : '  '
    console.log(`${prefix}${chalk.yellow(id)}: 位置=${formatPosition(player.position.v.x, player.position.v.y)}, 生命值=${player.health}/${player.maxHealth}, 資源=${player.resources}`)
  }
  console.log('')
}

function printMonsters() {
  if (!gameState.tree || !gameState.isJoined) {
    console.log(chalk.red('尚未連接或加入遊戲'))
    return
  }

  const monsters = gameState.tree.state.monsters
  console.log(chalk.cyan('\n=== 怪物列表 ==='))
  if (Object.keys(monsters).length === 0) {
    console.log('  沒有怪物')
  } else {
    for (const [id, monster] of Object.entries(monsters)) {
      console.log(`  ${chalk.red(id)}: 位置=${formatPosition(monster.position.v.x, monster.position.v.y)}, 生命值=${monster.health}/${monster.maxHealth}`)
    }
  }
  console.log('')
}

function printTurrets() {
  if (!gameState.tree || !gameState.isJoined) {
    console.log(chalk.red('尚未連接或加入遊戲'))
    return
  }

  const turrets = gameState.tree.state.turrets
  console.log(chalk.cyan('\n=== 炮塔列表 ==='))
  if (Object.keys(turrets).length === 0) {
    console.log('  沒有炮塔')
  } else {
    for (const [id, turret] of Object.entries(turrets)) {
      const owner = turret.ownerID === gameState.playerID ? chalk.green('(我的)') : ''
      console.log(`  ${chalk.blue(id)}: 位置=${formatPosition(turret.position.v.x, turret.position.v.y)}, 等級=${turret.level} ${owner}`)
    }
  }
  console.log('')
}

async function connect() {
  if (gameState.isConnected) {
    console.log(chalk.yellow('已經連接'))
    return
  }

  try {
    console.log(chalk.cyan(`正在連接到 ${wsUrl}...`))
    
    const runtime = new StateTreeRuntime({
      logger: {
        debug: () => {},
        info: (msg) => console.log(chalk.gray(`[StateTree] ${msg}`)),
        warn: (msg) => console.warn(chalk.yellow(`[StateTree] ${msg}`)),
        error: (msg) => console.error(chalk.red(`[StateTree] ${msg}`))
      }
    })

    await runtime.connect(wsUrl)
    gameState.runtime = runtime
    gameState.isConnected = true

    // Build landID
    let landID: string | undefined = roomId
    if (landID && !landID.includes(':')) {
      landID = `${LAND_TYPE}:${landID}`
    }

    const tree = new HeroDefenseStateTree(runtime, {
      landID: landID,
      playerID: undefined,
      deviceID: `cli-${Date.now()}`,
      metadata: { username: playerName },
      logger: {
        debug: () => {},
        info: (msg) => console.log(chalk.gray(`[StateTree] ${msg}`)),
        warn: (msg) => console.warn(chalk.yellow(`[StateTree] ${msg}`)),
        error: (msg) => console.error(chalk.red(`[StateTree] ${msg}`))
      }
    })

    gameState.tree = tree

    const joinResult = await tree.join()
    if (!joinResult.success) {
      throw new Error(joinResult.reason ?? '加入遊戲失敗')
    }

    gameState.playerID = joinResult.playerID ?? null
    gameState.isJoined = true

    console.log(chalk.green(`✅ 成功連接並加入遊戲！玩家 ID: ${gameState.playerID}`))
    
    // Set up state update listener for auto-refresh
    let statusUpdateTimer: NodeJS.Timeout | null = null
    tree.onPatch(() => {
      // Debounce status updates to avoid spam
      if (statusUpdateTimer) {
        clearTimeout(statusUpdateTimer)
      }
      statusUpdateTimer = setTimeout(() => {
        // Only print status if user hasn't typed anything recently
        if (rl.line === '') {
          printStatus()
        }
      }, 1000)
    })

    // Set up disconnect handler
    runtime.onDisconnect((code, reason, wasClean) => {
      console.log(chalk.yellow(`\n⚠️  連接已斷開 (code: ${code}, reason: ${reason})`))
      gameState.isConnected = false
      gameState.isJoined = false
      gameState.runtime = null
      gameState.tree = null
      gameState.playerID = null
    })

    printStatus()
  } catch (error) {
    console.error(chalk.red(`連接失敗: ${error}`))
    gameState.isConnected = false
    gameState.isJoined = false
    gameState.runtime = null
    gameState.tree = null
  }
}

async function disconnect() {
  if (!gameState.isConnected) {
    console.log(chalk.yellow('尚未連接'))
    return
  }

  if (gameState.tree) {
    gameState.tree.destroy()
  }
  if (gameState.runtime) {
    gameState.runtime.disconnect()
  }

  gameState.isConnected = false
  gameState.isJoined = false
  gameState.runtime = null
  gameState.tree = null
  gameState.playerID = null

  console.log(chalk.green('已斷開連接'))
}

async function handleCommand(line: string) {
  const trimmed = line.trim()
  if (!trimmed) {
    rl.prompt()
    return
  }

  const [command, ...args] = trimmed.split(/\s+/)

  try {
    switch (command.toLowerCase()) {
      case 'help':
      case 'h':
        printHelp()
        break

      case 'connect':
      case 'c':
        await connect()
        break

      case 'disconnect':
      case 'd':
        await disconnect()
        break

      case 'play':
      case 'p':
        if (!gameState.tree || !gameState.isJoined) {
          console.log(chalk.red('請先連接並加入遊戲'))
          break
        }
        try {
          const result = await gameState.tree.actions.play({})
          console.log(chalk.green(`✅ 遊戲開始！`))
          printStatus()
        } catch (error) {
          console.error(chalk.red(`開始遊戲失敗: ${error}`))
        }
        break

      case 'move':
      case 'm':
        if (!gameState.tree || !gameState.isJoined) {
          console.log(chalk.red('請先連接並加入遊戲'))
          break
        }
        if (args.length < 2) {
          console.log(chalk.red('用法: move <x> <y>'))
          break
        }
        try {
          const x = parseFloat(args[0])
          const y = parseFloat(args[1])
          gameState.tree.events.moveTo({ target: new Position2({ x, y }, false) })
          console.log(chalk.green(`✅ 移動到 ${formatPosition(x, y)}`))
        } catch (error) {
          console.error(chalk.red(`移動失敗: ${error}`))
        }
        break

      case 'shoot':
      case 's':
        if (!gameState.tree || !gameState.isJoined) {
          console.log(chalk.red('請先連接並加入遊戲'))
          break
        }
        if (args.length < 2) {
          console.log(chalk.red('用法: shoot <x> <y>'))
          break
        }
        try {
          const x = parseFloat(args[0])
          const y = parseFloat(args[1])
          gameState.tree.events.shoot({ x, y })
          console.log(chalk.green(`✅ 向 ${formatPosition(x, y)} 射擊`))
        } catch (error) {
          console.error(chalk.red(`射擊失敗: ${error}`))
        }
        break

      case 'place':
      case 't':
        if (!gameState.tree || !gameState.isJoined) {
          console.log(chalk.red('請先連接並加入遊戲'))
          break
        }
        if (args.length < 2) {
          console.log(chalk.red('用法: place <x> <y>'))
          break
        }
        try {
          const x = parseFloat(args[0])
          const y = parseFloat(args[1])
          gameState.tree.events.placeTurret({ position: new Position2({ x, y }, false) })
          console.log(chalk.green(`✅ 在 ${formatPosition(x, y)} 放置炮塔`))
        } catch (error) {
          console.error(chalk.red(`放置炮塔失敗: ${error}`))
        }
        break

      case 'upgrade-weapon':
      case 'uw':
        if (!gameState.tree || !gameState.isJoined) {
          console.log(chalk.red('請先連接並加入遊戲'))
          break
        }
        try {
          gameState.tree.events.upgradeWeapon({})
          console.log(chalk.green(`✅ 升級武器 (消耗 5 資源)`))
        } catch (error) {
          console.error(chalk.red(`升級武器失敗: ${error}`))
        }
        break

      case 'upgrade-turret':
      case 'ut':
        if (!gameState.tree || !gameState.isJoined) {
          console.log(chalk.red('請先連接並加入遊戲'))
          break
        }
        if (args.length < 1) {
          console.log(chalk.red('用法: upgrade-turret <炮塔ID>'))
          break
        }
        try {
          const turretID = parseInt(args[0], 10)
          if (isNaN(turretID)) {
            console.log(chalk.red('炮塔 ID 必須為數字'))
            break
          }
          gameState.tree.events.upgradeTurret({ turretID })
          console.log(chalk.green(`✅ 升級炮塔 ${turretID} (消耗 10 資源)`))
        } catch (error) {
          console.error(chalk.red(`升級炮塔失敗: ${error}`))
        }
        break

      case 'status':
      case 'st':
        printStatus()
        break

      case 'players':
      case 'pl':
        printPlayers()
        break

      case 'monsters':
      case 'mo':
        printMonsters()
        break

      case 'turrets':
      case 'tu':
        printTurrets()
        break

      case 'quit':
      case 'q':
      case 'exit':
        await disconnect()
        console.log(chalk.cyan('再見！'))
        process.exit(0)
        break

      default:
        console.log(chalk.red(`未知指令: ${command}`))
        console.log(chalk.yellow('輸入 help 查看可用指令'))
    }
  } catch (error) {
    console.error(chalk.red(`執行指令時發生錯誤: ${error}`))
  }

  rl.prompt()
}

// Main
console.log(chalk.cyan('🎮 Hero Defense CLI Client'))
console.log(chalk.gray(`伺服器: ${wsUrl}`))
console.log(chalk.gray(`玩家名稱: ${playerName}`))
console.log(chalk.gray(`房間 ID: ${roomId}`))
console.log(chalk.yellow('\n輸入 "help" 查看可用指令\n'))

rl.prompt()
rl.on('line', handleCommand)
rl.on('close', async () => {
  await disconnect()
  console.log(chalk.cyan('\n再見！'))
  process.exit(0)
})

// Auto-connect on startup
connect().catch((error) => {
  console.error(chalk.red(`自動連接失敗: ${error}`))
  console.log(chalk.yellow('請使用 "connect" 指令手動連接'))
})
