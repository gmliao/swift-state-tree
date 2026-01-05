[English](cookie-clicker.md) | [中文版](cookie-clicker.zh-TW.md)

# Cookie Clicker 範例

Cookie Clicker 是一個完整的多玩家遊戲範例，展示了 SwiftStateTree 的進階功能，包括：

- 多玩家狀態管理
- 私有狀態（per-player private state）
- 定期 Tick 處理
- Client Events 處理
- Action 與 Response

## 運行範例

**1. 啟動伺服器：**
```bash
cd Examples/HummingbirdDemo
swift run DemoServer
```

伺服器會在 `http://localhost:8080` 啟動。

**2. 生成客戶端代碼：**
```bash
cd WebClient
npm run codegen
```

**3. 啟動客戶端：**
```bash
npm run dev
```

然後在瀏覽器中打開 `http://localhost:5173`，導航到 Cookie Clicker 頁面。

## 核心功能

### 1. 多玩家狀態

遊戲狀態包含所有玩家的公開資訊和私有資訊：

```swift
@StateNodeBuilder
public struct CookieGameState: StateNodeProtocol {
    /// 所有玩家的公開狀態（所有人都能看到）
    @Sync(.broadcast)
    var players: [PlayerID: CookiePlayerPublicState] = [:]
    
    /// 每個玩家的私有狀態（只有該玩家能看到）
    @Sync(.perPlayer)
    var privateStates: [PlayerID: CookiePlayerPrivateState] = [:]
    
    /// 房間統計資訊
    @Sync(.broadcast)
    var totalCookies: Int = 0
    @Sync(.broadcast)
    var ticks: Int = 0
}
```

### 2. 私有狀態

使用 `@Sync(.perPlayer)` 實現每個玩家只能看到自己的私有狀態：

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

處理客戶端發送的事件（無回應）：

```swift
@Payload
public struct ClickCookieEvent: ClientEventPayload {
    public let amount: Int
    
    public init(amount: Int = 1) {
        self.amount = amount
    }
}

// 在 Land 定義中處理
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

### 4. Actions 與 Response

處理需要回應的操作：

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

// 在 Land 定義中處理
Rules {
    HandleAction(BuyUpgradeAction.self) { state, action, ctx in
        let (publicState, privateState) = state.ensurePlayerState(
            playerID: ctx.playerID
        )
        
        // 計算升級成本
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

### 5. 定期 Tick 處理

使用 `Lifetime` 區塊處理定期邏輯：

```swift
Lifetime {
    // 遊戲邏輯更新（可修改 state）
    Tick(every: .seconds(1)) { (state: inout CookieGameState, ctx: LandContext) in
        state.ticks += 1
        
        // 為每個玩家應用被動 cookie 生成
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
    
    // 網路同步（唯讀 callback 用於類型推斷）
    NetworkSync(every: .seconds(1)) { (state: CookieGameState, ctx: LandContext) in
        // 唯讀 callback - 會在 sync 時被調用
        // 請勿在此修改 state - 使用 Tick 進行 state 變更
        // 用於日誌記錄、指標收集或其他唯讀操作
    }
}
```

## 客戶端使用

生成的 composable 提供了完整的類型安全：

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

// 連接並加入遊戲
onMounted(async () => {
  await connect({ wsUrl: 'ws://localhost:8080/game/cookie' })
})

// 點擊 cookie（發送 Client Event）
async function handleClick() {
  await clickCookie({ amount: 1 })
}

// 購買升級（發送 Action）
async function handleBuy(upgradeID: string) {
  const response = await buyUpgrade({ upgradeID })
  if (response.success) {
    console.log(`升級成功！等級: ${response.upgradeLevel}`)
  }
}
</script>

<template>
  <div v-if="state">
    <!-- 顯示自己的狀態 -->
    <div>
      <h2>我的 Cookies: {{ state.players[currentPlayerID]?.cookies ?? 0 }}</h2>
      <button @click="handleClick">點擊 Cookie</button>
    </div>
    
    <!-- 顯示其他玩家 -->
    <div v-for="(player, id) in others" :key="id">
      {{ player.name }}: {{ player.cookies }} cookies
    </div>
  </div>
</template>
```

## 關鍵概念

1. **公開 vs 私有狀態**：使用 `@Sync(.broadcast)` 和 `@Sync(.perPlayer)` 控制資料可見性
2. **Client Events**：用於不需要回應的操作（如點擊）
3. **Actions**：用於需要伺服器驗證和回應的操作（如購買）
4. **Tick 處理**：定期執行遊戲邏輯（如被動生成 cookies）
5. **Sync Interval**：網路同步與遊戲邏輯分離執行，確保狀態更新以固定頻率發送給客戶端

## 完整原始碼

- **伺服器端定義**：[`Examples/HummingbirdDemo/Sources/DemoContent/CookieDemoDefinitions.swift`](../../Examples/HummingbirdDemo/Sources/DemoContent/CookieDemoDefinitions.swift)
- **伺服器主程式**：[`Examples/HummingbirdDemo/Sources/DemoServer/main.swift`](../../Examples/HummingbirdDemo/Sources/DemoServer/main.swift)
- **客戶端 Vue 組件**：[`Examples/HummingbirdDemo/WebClient/src/views/CookieGamePage.vue`](../../Examples/HummingbirdDemo/WebClient/src/views/CookieGamePage.vue)
