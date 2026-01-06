[English](cookie-clicker.md) | [中文版](cookie-clicker.zh-TW.md)

# Cookie Clicker Example

Cookie Clicker is a complete multiplayer game example showcasing SwiftStateTree's advanced features, including:

- Multiplayer state management
- Private state (per-player private state)
- Periodic Tick processing
- Client Events handling
- Actions and Responses

## Running the Example

**1. Start the server:**
```bash
cd Examples/HummingbirdDemo
swift run DemoServer
```

The server will start on `http://localhost:8080`.

**2. Generate client code:**
```bash
cd WebClient
npm run codegen
```

**3. Start the client:**
```bash
npm run dev
```

Then open `http://localhost:5173` in your browser and navigate to the Cookie Clicker page.

## Core Features

### 1. Multiplayer State

Game state contains public and private information for all players:

```swift
@StateNodeBuilder
public struct CookieGameState: StateNodeProtocol {
    /// Public state for all players (visible to everyone)
    @Sync(.broadcast)
    var players: [PlayerID: CookiePlayerPublicState] = [:]
    
    /// Private state for each player (only visible to that player)
    @Sync(.perPlayer)
    var privateStates: [PlayerID: CookiePlayerPrivateState] = [:]
    
    /// Room statistics
    @Sync(.broadcast)
    var totalCookies: Int = 0
    @Sync(.broadcast)
    var ticks: Int = 0
}
```

### 2. Private State

Use `@Sync(.perPlayer)` to ensure each player only sees their own private state:

```swift
@StateNodeBuilder
public struct CookiePlayerPrivateState: StateNodeProtocol {
    @Sync(.broadcast)
    var totalClicks: Int = 0
    
    @Sync(.broadcast)
    var upgrades: [String: Int] = [:]
}
```

### 3. Client Events

Handle events sent from client (no response):

```swift
@Payload
public struct ClickCookieEvent: ClientEventPayload {
    public let amount: Int
    
    public init(amount: Int = 1) {
        self.amount = amount
    }
}

// Handle in Land definition
Rules {
    HandleEvent(ClickCookieEvent.self) { state, event, ctx in
        let (publicState, privateState) = state.ensurePlayerState(
            playerID: ctx.playerID,
            defaultName: "Player"
        )
        publicState.cookies += event.amount
        privateState.totalClicks += 1
        state.totalCookies += event.amount
    }
}
```

### 4. Actions and Response

Handle operations that require responses:

```swift
@Payload
public struct BuyUpgradeAction: ActionPayload {
    public typealias Response = BuyUpgradeResponse
    
    public let upgradeID: String
    
    public init(upgradeID: String) {
        self.upgradeID = upgradeID
    }
}

@Payload
public struct BuyUpgradeResponse: ResponsePayload {
    public let success: Bool
    public let newCookies: Int
    public let newCookiesPerSecond: Int
    public let upgradeLevel: Int
}

// Handle in Land definition
Rules {
    HandleAction(BuyUpgradeAction.self) { state, action, ctx in
        let (publicState, privateState) = state.ensurePlayerState(
            playerID: ctx.playerID
        )
        
        // Calculate upgrade cost
        let currentLevel = privateState.upgrades[action.upgradeID] ?? 0
        let cost = calculateUpgradeCost(currentLevel, baseCost: 10)
        
        if publicState.cookies >= cost {
            publicState.cookies -= cost
            privateState.upgrades[action.upgradeID] = currentLevel + 1
            publicState.cookiesPerSecond = calculateCookiesPerSecond(
                upgrades: privateState.upgrades
            )
            
            return BuyUpgradeResponse(
                success: true,
                newCookies: publicState.cookies,
                newCookiesPerSecond: publicState.cookiesPerSecond,
                upgradeLevel: currentLevel + 1
            )
        } else {
            return BuyUpgradeResponse(
                success: false,
                newCookies: publicState.cookies,
                newCookiesPerSecond: publicState.cookiesPerSecond,
                upgradeLevel: currentLevel
            )
        }
    }
}
```

### 5. Periodic Tick Processing

Use `Lifetime` block to handle periodic logic:

```swift
Lifetime {
    // Game logic updates (can modify state)
    Tick(every: .seconds(1)) { (state: inout CookieGameState, ctx: LandContext) in
        state.ticks += 1
        
        // Apply passive cookie generation for each player
        var total = 0
        for (playerID, _) in state.players {
            let (publicState, privateState) = state.ensurePlayerState(
                playerID: playerID
            )
            let cps = calculateCookiesPerSecond(upgrades: privateState.upgrades)
            publicState.cookiesPerSecond = cps
            publicState.cookies += cps
            total += cps
        }
        state.totalCookies += total
    }
    
    // Network synchronization (read-only callback for type inference)
    StateSync(every: .seconds(1)) { (state: CookieGameState, ctx: LandContext) in
        // Read-only callback - will be called during sync
        // Do NOT modify state here - use Tick for state mutations
        // Use for logging, metrics, or other read-only operations
    }
}
```

## Client Usage

Generated composables provide complete type safety:

```vue
<script setup lang="ts">
import { useDemoGame } from './generated/demo-game/useDemoGame'

const {
  state,
  isJoined,
  connect,
  disconnect,
  clickCookie,
  buyUpgrade
} = useDemoGame()

// Connect and join game
onMounted(async () => {
  await connect({ wsUrl: 'ws://localhost:8080/game/cookie' })
})

// Click cookie (send Client Event)
async function handleClick() {
  await clickCookie({ amount: 1 })
}

// Buy upgrade (send Action)
async function handleBuy(upgradeID: string) {
  const response = await buyUpgrade({ upgradeID })
  if (response.success) {
    console.log(`Upgrade successful! Level: ${response.upgradeLevel}`)
  }
}
</script>

<template>
  <div v-if="state">
    <!-- Display own state -->
    <div>
      <h2>My Cookies: {{ state.players[currentPlayerID]?.cookies ?? 0 }}</h2>
      <button @click="handleClick">Click Cookie</button>
    </div>
    
    <!-- Display other players -->
    <div v-for="(player, id) in others" :key="id">
      {{ player.name }}: {{ player.cookies }} cookies
    </div>
  </div>
</template>
```

## Key Concepts

1. **Public vs Private State**: Use `@Sync(.broadcast)` and `@Sync(.perPlayer)` to control data visibility
2. **Client Events**: Used for operations that don't need responses (like clicking)
3. **Actions**: Used for operations that need server validation and responses (like purchasing)
4. **Tick Processing**: Periodically execute game logic (like passive cookie generation)
5. **Sync Interval**: Network synchronization runs separately from game logic, ensuring state updates are sent to clients at a fixed rate

## Complete Source Code

- **Server-side definition**: [`Examples/HummingbirdDemo/Sources/DemoContent/CookieDemoDefinitions.swift`](../../Examples/HummingbirdDemo/Sources/DemoContent/CookieDemoDefinitions.swift)
- **Server main program**: [`Examples/HummingbirdDemo/Sources/DemoServer/main.swift`](../../Examples/HummingbirdDemo/Sources/DemoServer/main.swift)
- **Client Vue component**: [`Examples/HummingbirdDemo/WebClient/src/views/CookieGamePage.vue`](../../Examples/HummingbirdDemo/WebClient/src/views/CookieGamePage.vue)
