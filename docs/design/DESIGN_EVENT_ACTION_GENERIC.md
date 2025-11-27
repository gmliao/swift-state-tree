# SwiftStateTree

## Generic Event Payload & Action 設計草案 v0.2（Land 版）

> 本文件描述 **Event（泛型 Payload）** 與 **Action（RPC）** 的正式設計，
> 已全面採用 **Land（世界/領域）** 作為 DSL 名稱。

---

# 0. 設計目標

本文件解決三件事：

### ① Event 要可擴充（不被 core 限制）

* core 不定義固定事件 enum
* event payload 由 app / feature 自己定義

### ② Action（RPC）要型別安全

* 每個 Action 定義自己的 Response
* handler / Transport 能在編譯期知道 input/output

### ③ 與 StateTree / Land DSL / Transport 完全相容

* 不動你的 StateTree 演算法
* 不動 SyncEngine（snapshot/diff）
* 多執行緒 diff 也不受影響

---

# 1. Event：Generic Payload 設計

## 1.1 core：Event Payload 協定

```swift
public protocol ClientEventPayload: Codable, Sendable {}
public protocol ServerEventPayload: Codable, Sendable {}
```

## 1.2 core：泛型 Event 容器

```swift
public enum Event<C: ClientEventPayload, S: ServerEventPayload>: Codable, Sendable {
    case fromClient(C)
    case fromServer(S)
}
```

* **core 不定義具體事件種類**
* App 端事件用 `C`、Server 端事件用 `S`

> 對應舊版 GameEvent，只是泛型版。

---

# 2. App/Feature 端定義自己的事件

## 2.1 Client Events

```swift
public enum MyClientEvents: ClientEventPayload {
    case playerReady(PlayerID)
    case heartbeat(Date)
    case uiInteraction(playerID: PlayerID, action: String)
    case playCard(playerID: PlayerID, cardID: Int)
}
```

## 2.2 Server Events

```swift
public enum MyServerEvents: ServerEventPayload {
    case stateUpdate(StateSnapshot)
    case gameEvent(GameEventDetail)
    case systemMessage(String)
}

public enum GameEventDetail: Codable, Sendable {
    case damage(from: PlayerID, to: PlayerID, amount: Int)
    case playerJoined(PlayerID, name: String)
    case playerReady(PlayerID)
    case gameStarted
}
```

## 2.3 Alias 統一命名

```swift
public typealias GameEvent = Event<MyClientEvents, MyServerEvents>
```

---

# 3. Land DSL 與 Event 整合

核心 LandDefinition 需支援 event 的型別參數。

## 3.1 core：LandDefinition

```swift
public struct LandDefinition<
    State: StateNodeProtocol,
    ClientE: ClientEventPayload,
    ServerE: ServerEventPayload,
    Action: Codable & Sendable
> {
    public let id: String
    public let nodes: [LandNode]

    public let clientEventType: ClientE.Type
    public let serverEventType: ServerE.Type
    public let actionType: Action.Type
}
```

## 3.2 Land() DSL 建構器

```swift
public func Land<
    State: StateNodeProtocol,
    ClientE: ClientEventPayload,
    ServerE: ServerEventPayload,
    Action: Codable & Sendable
>(
    _ id: String,
    using stateType: State.Type,
    clientEvents: ClientE.Type,
    serverEvents: ServerE.Type,
    actions: Action.Type,
    @LandDSL _ content: () -> [LandNode]
) -> LandDefinition<State, ClientE, ServerE, Action> {
    .init(
        id: id,
        nodes: content(),
        clientEventType: clientEvents,
        serverEventType: serverEvents,
        actionType: actions
    )
}
```

---

# 4. Land DSL 實際使用範例

```swift
let matchLand = Land(
    "match-3",
    using: GameStateTree.self,
    clientEvents: MyClientEvents.self,
    serverEvents: MyServerEvents.self,
    actions: GameAction.self
) {

    Config {
        MaxPlayers(4)
        Tick(every: .milliseconds(100))
    }

    AllowedClientEvents {
        MyClientEvents.playerReady
        MyClientEvents.heartbeat
        MyClientEvents.uiInteraction
        MyClientEvents.playCard
    }

    On(MyClientEvents.self) { state, event, ctx in
        switch event {

        case .playerReady(let id):
            await handlePlayerReady(&state, id, ctx)

        case .heartbeat(let ts):
            state.playerLastActivity[ctx.playerID] = ts

        case .uiInteraction(let id, let action):
            analytics.track(id, action: action)

        case .playCard(let id, let cardID):
            await handlePlayCard(&state, id, cardID, ctx)
        }
    }
}
```

> `AllowedClientEvents` 只限制 Client→Land。
> ServerEvents 不需要限制（Land 自己送）。

---

# 5. Action（RPC）設計

## 5.1 core：ActionPayload 協定

```swift
public protocol ActionPayload: Codable, Sendable {
    associatedtype Response: Codable & Sendable
}
```

每個 Action 都要有自己的 Response 型別。

---

## 5.2 App 端定義 Action 與 Response

### Response

```swift
public enum GameActionResponse: Codable, Sendable {
    case joinResult(JoinResponse)
    case hand([Card])
    case card(Card)
    case landInfo(LandInfo)
    case empty
}
```

### Action

```swift
public enum GameAction: ActionPayload {
    public typealias Response = GameActionResponse

    case getPlayerHand(PlayerID)
    case getLandInfo

    case join(playerID: PlayerID, name: String)
    case drawCard(playerID: PlayerID)
    case attack(attacker: PlayerID, target: PlayerID, damage: Int)
}
```

---

# 6. Land DSL：Action Handler

## 6.1 Handler typealias

```swift
public typealias ActionHandler<State, Act: ActionPayload> =
    (inout State, Act, LandContext) async throws -> Act.Response
```

## 6.2 DSL Node

```swift
public struct ActionNode<State, Act: ActionPayload>: LandNode {
    public let handler: ActionHandler<State, Act>
}

public func Action<Act: ActionPayload>(
    _ type: Act.Type,
    _ handler: @escaping ActionHandler<State, Act>
) -> LandNode {
    ActionNode(handler: handler)
}
```

---

# 7. Land 內使用範例（完整）

```swift
Action(GameAction.self) { state, action, ctx in
    switch action {

    case .getPlayerHand(let id):
        let cards = state.hands[id]?.cards ?? []
        return .hand(cards)

    case .getLandInfo:
        let info = LandInfo(
            id: ctx.landID,
            playerCount: state.players.count
        )
        return .landInfo(info)

    case .join(let id, let name):
        return try await handleJoin(&state, id: id, name: name, ctx: ctx)

    case .drawCard(let id):
        return try await handleDrawCard(&state, id: id, ctx: ctx)

    case .attack(let attacker, let target, let damage):
        return try await handleAttack(
            &state, attacker: attacker, target: target, damage: damage, ctx: ctx
        )
    }
}
```

---

# 8. TransportMessage（泛型 + Land 版）

```swift
public enum TransportMessage<Action, ClientE, ServerE>: Codable
where
    Action: ActionPayload,
    ClientE: ClientEventPayload,
    ServerE: ServerEventPayload
{
    case action(
        requestID: String,
        landID: String,
        action: Action
    )

    case actionResponse(
        requestID: String,
        response: Action.Response
    )

    case event(
        landID: String,
        event: Event<ClientE, ServerE>
    )
}
```

App 端別名：

```swift
typealias GameMessage =
    TransportMessage<GameAction, MyClientEvents, MyServerEvents>
```

---

# 9. 與 StateTree / SyncEngine 完整相容

此設計不影響：

### ✓ 單執行緒 mutate LandStateTree（LandActor）

Land 內接受 Action / Event → 修改 StateTree。

### ✓ 多執行緒 snapshot → diff 計算（SyncEngine）

仍維持高效、多執行緒、可並行。

### ✓ Per-player 過濾

ServerEvents 的 `.stateUpdate(...)` 照原本路線走。

### ✓ Land 可以擁有多種事件型別

每個 Land 可定義不同的 ClientEvents / ServerEvents / Action。

---

# 10. 給 Cursor 使用的建議

1. 把這份文件放：
   `docs/design/DESIGN_EVENT_ACTION_GENERIC.md`

2. 在 Cursor system prompt 加：

   * Land DSL 的事件與 RPC 需使用泛型設計
   * 所有 Land 都必須明確指定：
     `clientEvents`, `serverEvents`, `actions`

3. 未來要產生 TypeScript SDK 時：

   * 可從 `MyClientEvents` / `MyServerEvents` / `GameAction` 自動導出 Schema。
