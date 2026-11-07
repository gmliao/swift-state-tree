[English](land-dsl.md) | [中文版](land-dsl.zh-TW.md)

# Land DSL

Land 是伺服器邏輯的最小可運行單位，負責定義加入規則、行為規則與生命周期。
`Land(...)` 會收集 DSL 節點並產生 `LandDefinition<State>`，交由 Runtime 執行。

## 設計說明

- Land DSL 只描述行為，不暴露 Transport 細節
- handlers 以同步方式定義；輸出請用 `ctx.emitEvent(...)` / `ctx.requestSync*()`，非同步 I/O 請在 handler 之外處理（例如 Resolver）。
- 事件型別註冊（Client/ServerEvents）用於 schema 與驗證

## 基本結構

```swift
Land("demo", using: GameState.self) {
    AccessControl { ... }
    ClientEvents { ... }
    ServerEvents { ... }
    Rules { ... }
    Lifetime { ... }
}
```

## AccessControl

控制房間可見性與人數上限：

- `AllowPublic(true|false)`
- `MaxPlayers(Int)`

## ClientEvents / ServerEvents

註冊事件型別（schema/驗證/工具會用到）：

```swift
ClientEvents {
    Register(ClickCookieEvent.self)
}

ServerEvents {
    Register(PongEvent.self)
}
```

server event 是通知，同步的狀態才是真實來源。仍在加入中的 session，會在它的 firstSync 之後依送出順序收到送給它的 targeted event，而這些 event 的效果已經包含在該 firstSync 裡（見 [Transport](../transport/README.zh-TW.md#join-與-session-流程)）。

## Rules

規則區塊定義 Join/Leave 與 Action/Event 行為：

- `CanJoin`：加入前驗證，回傳 `JoinDecision`
- `OnJoin` / `OnLeave`：加入或離開後處理
- `HandleAction`：處理 Action（有回應）
- `HandleEvent`：處理 Client Event（無回應）

```swift
Rules {
    CanJoin { state, session, ctx in
        .allow(playerID: PlayerID(session.playerID))
    }

    OnJoin { state, ctx in
        // mutate state
    }

    HandleAction(JoinAction.self) { state, action, ctx in
        return JoinResponse(status: "ok")
    }

    HandleEvent(ClickCookieEvent.self) { state, event, ctx in
        // mutate state
    }
}
```

### 必須至多套用一次的 action

transport 至多傳遞一次 action，且不會對重送去重（見 SDK 的[傳遞語意](../sdk/README.zh-TW.md#傳遞語意至多一次at-most-once)）：
- **連線關閉後，結果未知。** 因 `ConnectionClosedError` 而被 reject 的等待中 action，可能已套用，也可能沒有。
- **SDK 不會重送。** 是否重送由 app 決定，伺服器會把重送當成一個新的請求來套用。
- **重新加入後，以 firstSync 的狀態為準**，判斷 action 是否生效。
- **在有 tick 的 land 上，回應只是 ACK，代表「已排入佇列」，不代表「已套用」。** handler 在之後的 tick 執行，它的回傳值不會送到 client。請從狀態讀取結果。

不能套用兩次的 action（例如購買），請在 land 的狀態裡去重：
- client 在 payload 裡放一個 ID，每次操作選一次，重送時原封不動再送；
- handler 把已套用過的 ID 記在狀態裡，遇到看過的 ID 就忽略。

放在狀態裡，這個檢查就是 land 決定性 turn 的一部分，錄製、replay 與 reevaluation 都會重現它；放在狀態以外的表則看不到。歷史的長度由 app 決定上限：比上限更舊的重送會再套用一次。

```swift
@StateNodeBuilder
struct ShopState: StateNodeProtocol {
    @Sync(.perPlayerSlice())
    var coins: [PlayerID: Int] = [:]

    /// Purchase IDs this land has applied, per player, newest last. Server-only: clients
    /// don't need it. Bounded by the app (see `maxAppliedPurchases`).
    @Sync(.serverOnly)
    var appliedPurchases: [PlayerID: [String]] = [:]

    init() {}
}

@Payload
struct BuyItemAction: ActionPayload {
    typealias Response = BuyItemResponse

    /// Chosen by the client once per purchase, and sent again unchanged if it resends.
    let purchaseID: String
    let itemID: String
    let price: Int
}

@Payload
struct BuyItemResponse: ResponsePayload {
    let applied: Bool
    let coins: Int
}

/// How many purchase IDs a player's history keeps; a resend older than that applies again.
let maxAppliedPurchases = 64

// In the land's Rules:
HandleAction(BuyItemAction.self) { (state: inout ShopState, action: BuyItemAction, ctx: LandContext) throws -> BuyItemResponse in
    let player = ctx.playerID
    let coins = state.coins[player] ?? 0
    var applied = state.appliedPurchases[player] ?? []
    // Already applied: change nothing.
    guard !applied.contains(action.purchaseID) else {
        return BuyItemResponse(applied: false, coins: coins)
    }
    guard coins >= action.price else {
        return BuyItemResponse(applied: false, coins: coins)
    }
    state.coins[player] = coins - action.price
    applied.append(action.purchaseID)
    if applied.count > maxAppliedPurchases {
        applied.removeFirst(applied.count - maxAppliedPurchases)
    }
    state.appliedPurchases[player] = applied
    return BuyItemResponse(applied: true, coins: coins - action.price)
}
```

- `appliedPurchases` 是 `.serverOnly`：client 不需要它，也不佔傳輸量。
- 歷史以玩家為單位。上限要遠大於「重送仍可能發生的期間內，一個玩家能送出的這類 action 數量」。
- 在有 tick 的 land 上，client 收到的 `BuyItemResponse` 只是 ACK，`coins` 要從狀態讀。

## LandContext

Handler 會取得 `LandContext`，包含：

- `landID`, `playerID`, `clientID`, `sessionID`, `deviceID`
- `metadata`（來自 join/JWT/guest）
- `services`（注入外部服務）
- `emitEvent(...)`, `requestSyncNow()`, `requestSyncBroadcastOnly()`

LandContext 是 request-scoped，請避免保存引用。

## Resolver

`HandleAction`、`OnJoin`、`OnInitialize` 等可宣告 resolver。
Resolver 先並行執行，成功後再同步進入 handler。

## Lifetime

- `Tick(every:)`：遊戲邏輯更新（可修改 state）
- `StateSync(every:)`：狀態同步（只讀 callback，會被調用）
- `DestroyWhenEmpty(after:)`：空房間自動關閉
- `PersistSnapshot(every:)`：快照週期
- `OnInitialize` / `OnFinalize` / `AfterFinalize` / `OnShutdown`
- `OnInitialize(resolvers:onResolverFailure:)`：resolver 丟錯時預設會讓 land 初始化失敗（`.failLand`）；`.continue` 則在沒有 resolver 輸出的情況下執行 OnInitialize。見 [Resolver 期限](resolver.zh-TW.md#期限)

```swift
Lifetime {
    // 遊戲邏輯更新（20Hz）
    Tick(every: .milliseconds(50)) { (state: inout GameState, ctx: LandContext) in
        // 使用 ctx.tickId (Int64) 進行確定性、重播相容的邏輯
        if let tickId = ctx.tickId {
            let tickIntervalSeconds = 0.05  // 50ms = 0.05s
            let gameTime = Double(tickId) * tickIntervalSeconds
            state.position += state.velocity * tickIntervalSeconds
        }
    }
    
    // 網路同步（10Hz）
    // Callback 是唯讀的，會在 sync 時被調用 - 請勿修改 state
    StateSync(every: .milliseconds(100)) { (state: GameState, ctx: LandContext) in
        // 唯讀 callback - 會在 sync 時被調用
        // 用於日誌記錄、指標收集或其他唯讀操作
        // Network sync 機制會在 callback 之後觸發網路同步
    }
    // 如果未設定 StateSync，會自動配置為與 tick interval 相同
}
```

**注意**：`Tick` 是重播功能中唯一可修改 state 的來源。`StateSync` 僅觸發狀態同步，不會修改 state。可選的 callback 是唯讀的，會在 sync 操作時被調用，用於日誌記錄、指標收集或其他唯讀操作。
