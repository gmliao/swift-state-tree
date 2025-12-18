import { ref, computed, reactive } from 'vue'
import type { Ref } from 'vue'
import { StateTreeRuntime } from '@swiftstatetree/sdk/core'
import { DemoGameStateTree } from '../generated/demo-game'
import type {
  CookieGameState,
  CookiePlayerPublicState,
  CookiePlayerPrivateState
} from '../generated/defs'

interface ConnectOptions {
  wsUrl: string
  playerName?: string
}

interface OtherPlayerSummary {
  playerID: string
  name: string
  cookies: number
  cps: number
}

interface RoomSummary {
  totalCookies: number
  ticks: number
  playerCount: number
}

const runtime = ref<StateTreeRuntime | null>(null)
const tree = ref<DemoGameStateTree | null>(null)

const state: Ref<CookieGameState | null> = ref<CookieGameState | null>(null)
const currentPlayerID = ref<string | null>(null)

const isConnecting = ref(false)
const isConnected = ref(false)
const isJoined = ref(false)
const lastError = ref<string | null>(null)

export function useCookieGameTree() {

  async function connect(opts: ConnectOptions): Promise<void> {
    if (isConnecting.value || isConnected.value) return

    isConnecting.value = true
    lastError.value = null

    try {
      const r = new StateTreeRuntime()
      await r.connect(opts.wsUrl)
      runtime.value = r
      isConnected.value = true

      const metadata: Record<string, any> = {}
      if (opts.playerName && opts.playerName.trim().length > 0) {
        metadata.username = opts.playerName.trim()
      }

      const t = new DemoGameStateTree(r, {
        metadata,
        logger: {
          debug: () => {},
          info: (msg) => console.log('[StateTree]', msg),
          warn: (msg) => console.warn('[StateTree]', msg),
          error: (msg) => console.error('[StateTree]', msg)
        }
      })
      tree.value = t

      const joinResult = await t.join()
      if (!joinResult.success) {
        throw new Error(joinResult.reason ?? 'Join failed')
      }

      currentPlayerID.value = joinResult.playerID ?? null
      
      // Make t.state reactive so Vue can track changes directly
      // This allows direct access like state.players[playerID].cookies in templates
      const reactiveState = reactive(t.state as CookieGameState)
      state.value = reactiveState
      
      // Override t.state to point to reactiveState so syncInto updates it directly
      // This way syncInto will update the reactive object and Vue tracks it automatically
      Object.defineProperty(t, 'state', {
        get: () => reactiveState,
        enumerable: true,
        configurable: true
      })
      
      isJoined.value = true
    } catch (error) {
      const message = (error as Error).message ?? String(error)
      lastError.value = message
      console.error('Connect/join failed:', error)
      await disconnect()
    } finally {
      isConnecting.value = false
    }
  }

  async function disconnect(): Promise<void> {
    if (tree.value) {
      tree.value.destroy()
    }
    if (runtime.value && 'disconnect' in runtime.value && typeof runtime.value.disconnect === 'function') {
      runtime.value.disconnect()
    }
    runtime.value = null
    tree.value = null
    state.value = null
    currentPlayerID.value = null
    isConnected.value = false
    isJoined.value = false
  }

  async function clickCookie(amount = 1): Promise<void> {
    if (!tree.value || !isJoined.value) return
    try {
      await tree.value.events.clickCookie({ amount })
    } catch (error) {
      console.error('clickCookie failed:', error)
      lastError.value = (error as Error).message ?? String(error)
    }
  }

  async function buyUpgrade(id: string): Promise<void> {
    if (!tree.value || !isJoined.value) return
    try {
      const res = await tree.value.actions.buyUpgrade({ upgradeID: id })
      if (!res.success) {
        lastError.value = 'Upgrade failed (not enough cookies?)'
      } else {
        lastError.value = null
      }
    } catch (error) {
      console.error('buyUpgrade failed:', error)
      lastError.value = (error as Error).message ?? String(error)
    }
  }

  const selfPublicState = computed<CookiePlayerPublicState | null>(() => {
    if (!state.value || !currentPlayerID.value) return null
    if (!state.value.players) return null
    return state.value.players[currentPlayerID.value] ?? null
  })

  const selfPrivateState = computed<CookiePlayerPrivateState | null>(() => {
    if (!state.value || !currentPlayerID.value) return null
    if (!state.value.privateStates) return null
    return state.value.privateStates[currentPlayerID.value] ?? null
  })

  const otherPlayers = computed<OtherPlayerSummary[]>(() => {
    if (!state.value || !currentPlayerID.value) return []
    if (!state.value.players) return []
    return Object.entries(state.value.players)
      .filter(([playerID]) => playerID !== currentPlayerID.value)
      .map(([playerID, s]) => ({
        playerID,
        name: s.name,
        cookies: s.cookies,
        cps: s.cookiesPerSecond
      }))
  })

  const roomSummary = computed<RoomSummary | null>(() => {
    if (!state.value) return null
    const players = state.value.players ?? {}
    return {
      totalCookies: state.value.totalCookies ?? 0,
      ticks: state.value.ticks ?? 0,
      playerCount: Object.keys(players).length
    }
  })

  return {
    state,
    currentPlayerID,
    selfPublicState,
    selfPrivateState,
    otherPlayers,
    roomSummary,
    isConnecting,
    isConnected,
    isJoined,
    lastError,
    connect,
    disconnect,
    clickCookie,
    buyUpgrade
  }
}



