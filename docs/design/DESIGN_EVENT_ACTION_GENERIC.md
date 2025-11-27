# SwiftStateTree

## Generic Event Payload & Action 設計 v1（Land DSL 優化版）

> 本文件同步 Land DSL v1 規格，描述 **Event（泛型 Payload）** 與 **Action（型別導向 RPC）** 的正式設計，並說明 Transport 端如何與 `@Land` 語法糖協作。
> 若需 DSL 本體與 builder 流程，請對照 `docs/design/DESIGN_LAND_DSL.md`。

---

# 0. 設計目標

1. **Event 完全型別導向**：core 只提供協定與泛型容器，事件型別由 App/Feature 自行定義，並可透過 macro 產出語義化 handler (`OnReady`, `OnChat` ...)。
2. **Action 不再綁單一 enum**：每個 Action 自成一個 `struct`/`enum`，以 `Action(FireMissile.self) { ... }` 方式註冊，Handler 回傳 `some Codable & Sendable`，runtime 以 `AnyCodable` 打包回應。
3. **與 StateTree / SyncEngine / Transport 完整相容**：單線程 LandKeeper 仍操控 StateTree，SyncEngine diff 流程不需修改，Transport 透過 `ActionEnvelope` + `Event` 泛型即可對應所有型別。

---

# 1. Protocol 基礎

```swift
public protocol ActionPayload: Codable, Sendable {}
public protocol ClientEventPayload: Codable, Sendable {}
public protocol ServerEventPayload: Codable, Sendable {}
```

* **ActionPayload**：Client → Land 的「意圖」或 RPC。
* **ClientEventPayload**：Client → Land 的即時事件（需經 `AllowedClientEvents` 細項授權）。
* **ServerEventPayload**：Land → Client 的廣播事件。

---

# 2. Generic Event 容器（core）

```swift
public enum Event<C: ClientEventPayload, S: ServerEventPayload>: Codable, Sendable {
    case fromClient(C)
    case fromServer(S)
}
```

* core 不定義具體事件名稱，只負責傳遞 `C` / `S`。
* 與舊版 `GameEvent` 對齊，但改為泛型。

---

# 3. App / Feature 自訂事件

```swift
@GenerateLandEventHandlers
enum ClientEvents: ClientEventPayload {
    case ready
    case move(Vec2)
    case chat(String)
}

enum ServerEvents: ServerEventPayload {
    case systemMessage(String)
    case stateUpdate(StateSnapshot)
}
```

* `@GenerateLandEventHandlers` 會產出 `OnReady`, `OnMove`, `OnChat` 等語法糖（參見 §6）。
* 若需要多個 Land，各自定義自己的 `ClientEvents` / `ServerEvents`。
* Macro 會針對每個 case 生成唯一的 `OnXxx` 函式；若新增、刪除或改名 case，對應 handler API 會同步調整，若同名 case 或手動定義衝突函式會造成編譯錯誤以避免語義不一致。

Alias（可選）：

```swift
public typealias GameEvent = Event<ClientEvents, ServerEvents>
```

---

# 4. LandDefinition 與 `@Land`

## 4.1 LandDefinition（v1）

```swift
public struct LandDefinition<
    State: StateNodeProtocol,
    ClientE: ClientEventPayload,
    ServerE: ServerEventPayload
>: Sendable {
    public let id: String
    public let stateType: State.Type
    public let clientEventType: ClientE.Type
    public let serverEventType: ServerE.Type
    public let config: LandConfig
    public let actionHandlers: [AnyActionHandler<State>]
    public let eventHandlers: [AnyClientEventHandler<State, ClientE>]
    public let lifetimeHandlers: LifetimeHandlers<State>
}
```

* `LandConfig`：AccessControl / Tick / Idle / etc.
* `AnyActionHandler`：型別抹除後的 Action 處理器。
* `AnyClientEventHandler`：型別抹除後的事件處理器（含 macro 產生的語義化 handler）。
* `LifetimeHandlers`：OnJoin / OnLeave / Tick / OnShutdown ...

## 4.2 Land Builder 入口

```swift
@resultBuilder
public enum LandDSL {
    public static func buildBlock(_ components: LandNode...) -> [LandNode] {
        components
    }
}

public func Land<
    State: StateNodeProtocol,
    ClientE: ClientEventPayload,
    ServerE: ServerEventPayload
>(
    _ id: String,
    using stateType: State.Type,
    clientEvents: ClientE.Type,
    serverEvents: ServerE.Type,
    @LandDSL _ content: () -> [LandNode]
) -> LandDefinition<State, ClientE, ServerE> {
    LandBuilder.build(
        id: id,
        stateType: stateType,
        clientEvents: clientEvents,
        serverEvents: serverEvents,
        nodes: content()
    )
}
```

## 4.3 `@Land` Macro 語法糖

```swift
@Land(GameState.self, client: ClientEvents.self, server: ServerEvents.self)
struct GameLand {
    static var body: some LandDSL {
        AccessControl { ... }
        Rules { ... }
        Lifetime { ... }
    }
}
```

規範：

* `struct` 內要有 `static var body: some LandDSL`，macro 會把這段內容餵給 `Land(...)`。
* `@Land` 參數 `id:` 可選；沒填時會以 struct 名稱推導（去掉尾巴 `Land`，再轉為 kebab-case）。

Macro 會產生 `static var definition: LandDefinition<...>`，且自動呼叫 `Land(...)`。

---

# 5. AccessControl / Rules / Lifetime 區塊

* **AccessControl**：`AllowPublic()`, `MaxPlayers(_:)`，未來可擴充 role-based / custom policy。
* **Rules**：`OnJoin`、`OnLeave`、`AllowedClientEvents`、`Action(...)`、`On(ClientEvents.self)`、`OnReady` 等語法糖全部收斂在此。
* **Lifetime**：`Tick(every:_:)`、`DestroyWhenEmpty(after:)`、`PersistSnapshot(every:)`、`OnShutdown` 等生命週期設定。Tick handler 會儲存在 `LifetimeHandlers` 供 LandKeeper 掛載。

---

# 6. Event DSL（泛型 + 語義化 handler）

## 6.1 基礎 handler

```swift
public struct AnyClientEventHandler<State: StateNodeProtocol, E: ClientEventPayload>: LandNode {
    let handler: @Sendable (inout State, E, LandContext) async -> Void
}

public func On<State, E: ClientEventPayload>(
    _ type: E.Type,
    _ body: @escaping @Sendable (inout State, E, LandContext) async -> Void
) -> AnyClientEventHandler<State, E> {
    AnyClientEventHandler(handler: body)
}
```

## 6.2 AllowedClientEvents

```swift
public struct AllowedClientEventsNode: LandNode {
    public let allowed: Set<AnyHashable>
}

public func AllowedClientEvents(_ builder: () -> [AnyHashable]) -> AllowedClientEventsNode {
    AllowedClientEventsNode(allowed: Set(builder()))
}
```

Transport 僅允許 `allowed` 內的 case 進入 LandKeeper。

## 6.3 Macro 產生的語義化 handler

`@GenerateLandEventHandlers` 會為每個 enum case 產生一個 `OnXxx`，本質是包裝 `On(ClientEvents.self)`：

```swift
func OnReady<State: StateNodeProtocol>(
    _ body: @escaping @Sendable (inout State, LandContext) async -> Void
) -> AnyClientEventHandler<State, ClientEvents> {
    On(ClientEvents.self) { state, event, ctx in
        if case .ready = event {
            await body(&state, ctx)
        }
    }
}
```

使用者只需寫：

```swift
Rules {
    AllowedClientEvents {
        ClientEvents.ready
        ClientEvents.move
        ClientEvents.chat
    }

    OnReady { state, ctx in
        state.readyPlayers.insert(ctx.playerID)
    }

    OnMove { state, vec, ctx in
        state.players[ctx.playerID]?.position = vec
    }

    OnChat { state, msg, ctx in
        await ctx.sendEvent(
            ServerEvents.systemMessage("[\(ctx.playerID.rawValue)] \(msg)"),
            to: .all
        )
    }
}
```

---

# 7. Action DSL（型別導向）

## 7.1 `ActionPayload` 寫法

```swift
struct Join: ActionPayload { let name: String }
struct Move: ActionPayload { let x: Int; let y: Int }
struct Attack: ActionPayload { let target: PlayerID; let damage: Int }
struct GetInventory: ActionPayload { let owner: PlayerID }
```

每個 Action 可置於獨立檔案，維持模組化。

## 7.2 Handler 介面與型別抹除

```swift
public struct AnyActionHandler<State: StateNodeProtocol>: LandNode {
    let type: Any.Type
    let handler: @Sendable (inout State, Any, LandContext) async throws -> AnyCodable

    func canHandle(_ actionType: Any.Type) -> Bool {
        actionType == type
    }

    func invoke<A: ActionPayload>(
        _ state: inout State,
        action: A,
        ctx: LandContext
    ) async throws -> AnyCodable {
        try await handler(&state, action, ctx)
    }
}

public func Action<State, A: ActionPayload>(
    _ type: A.Type,
    _ body: @escaping @Sendable (inout State, A, LandContext) async throws -> some Codable & Sendable
) -> AnyActionHandler<State> {
    AnyActionHandler(
        type: A.self,
        handler: { state, anyAction, ctx in
            guard let action = anyAction as? A else {
                throw LandError.invalidActionType
            }
            let result = try await body(&state, action, ctx)
            return AnyCodable(result)
        }
    )
}
```

* Handler 可 `throw`，錯誤會被 LandKeeper 傳回給 Transport。
* 回傳值使用 `some Codable & Sendable`，由編譯器推論實際型別，runtime 轉為 `AnyCodable`。

## 7.3 Rules 區塊中的 Action

```swift
Rules {
    Action(Join.self) { state, action, ctx in
        state.players[ctx.playerID] = PlayerState(name: action.name)
        return VoidResponse.ok
    }

    Action(Move.self) { state, action, ctx in
        state.players[ctx.playerID]?.position = Vec2(action.x, action.y)
        return VoidResponse.ok
    }

    Action(GetInventory.self) { state, action, ctx in
        return state.players[action.owner]?.inventory ?? []
    }
}
```

對於會回傳不同資料型別的 Action（例如 `GetInventory` 回傳 `[Item]`），Transport 端可以透過 schema codegen 或手動 switch `ActionEnvelope.typeIdentifier` 來還原：

```swift
switch envelope.typeIdentifier {
case "Game.Join":
    let payload = try decoder.decode(Join.self, from: envelope.payload)
    ...
case "Game.GetInventory":
    let payload = try decoder.decode(GetInventory.self, from: envelope.payload)
    let response = try await land.handle(payload)
    let decoded = response.base as? [Item]
    ...
default:
    throw TransportError.unknownAction
}
```

這段流程與 `docs/design/DESIGN_LAND_DSL.md` 的 Rules 區塊相互對應，保證編譯期型別與 runtime 封包一致。

---

# 8. LandContext（請求級上下文）

```swift
public struct LandContext: Sendable {
    public let landID: String
    public let playerID: PlayerID
    public let clientID: ClientID
    public let sessionID: SessionID
    public let services: LandServices

    public func sendEvent(_ event: any ServerEventPayload, to target: EventTarget) async {
        await sendEventHandler(event, target)
    }

    public func syncNow() async {
        await syncHandler()
    }

    private let sendEventHandler: @Sendable (any ServerEventPayload, EventTarget) async -> Void
    private let syncHandler: @Sendable () async -> Void
}
```

* **Request-scoped**：每次 Action/Event 進入 LandKeeper 時建立。
* **Transport 隔離**：只透過閉包回呼觸發 WebSocket / HTTP 傳輸，Land 端不需要知道底層協定。

---

# 9. Transport：ActionEnvelope + Event

## 9.1 ActionEnvelope

為了支援「多個 Action 型別」，Transport 以 `ActionEnvelope` 表示一次 RPC：

```swift
public struct ActionEnvelope: Codable, Sendable {
    public let typeIdentifier: String   // e.g. fully-qualified Swift type name
    public let payload: Data            // JSON / MsgPack 編碼後的資料
}
```

* **encode**：Client 端根據即將送出的 Action 型別，填入 `typeIdentifier`（可由 codegen/macro 提供常數），並將 `ActionPayload` 序列化成 `payload`。
* **decode**：Land Transport 依照 `typeIdentifier` 找到對應的 Swift 型別並解碼，再交由 LandKeeper 處理。

## 9.2 TransportMessage（v1）

```swift
public enum TransportMessage<ClientE, ServerE>: Codable
where ClientE: ClientEventPayload, ServerE: ServerEventPayload {
    case action(
        requestID: String,
        landID: String,
        action: ActionEnvelope
    )

    case actionResponse(
        requestID: String,
        response: AnyCodable
    )

    case event(
        landID: String,
        event: Event<ClientE, ServerE>
    )
}
```

* `AnyCodable` 回傳值可由 TypeScript / Kotlin SDK 轉回動態物件，或透過 schema codegen 轉型。
* 若需要靜態型別，可在 codegen 時為每個 Action 建立 Response decoder。

## 9.3 App 別名

```swift
typealias GameMessage = TransportMessage<ClientEvents, ServerEvents>
```

---

# 10. LandKeeper 運作概念

```swift
actor LandKeeper<State, ClientE, ServerE>
where State: StateNodeProtocol,
      ClientE: ClientEventPayload,
      ServerE: ServerEventPayload {

    let definition: LandDefinition<State, ClientE, ServerE>
    private var state: State = .init()

    func handleAction(_ envelope: ActionEnvelope, ctx: LandContext) async throws -> AnyCodable {
        let action = try decodeAction(from: envelope)
        guard let handler = definition.actionHandlers.first(where: { $0.canHandle(type(of: action)) }) else {
            throw LandError.actionNotRegistered
        }
        return try await handler.invoke(&state, action: action, ctx: ctx)
    }

    func handleClientEvent(_ event: ClientE, ctx: LandContext) async {
        for handler in definition.eventHandlers {
            await handler.handler(&state, event, ctx)
        }
    }

    // Tick / lifetime 依據 definition.lifetimeHandlers 設定
}
```

* `decodeAction(from:)` 由 Transport 提供，負責把 `ActionEnvelope` 轉成實際 `ActionPayload`。
* Event handler 無需判斷型別，macro 已經拆好。
* Tick handler 在 `docs/design/DESIGN_LAND_DSL.md` 的 Lifetime 章節有詳述，包含 copy-back pattern 以確保 `State` mutation 會寫回 `LandKeeper`。

---

# 11. 相容性說明

* **StateTree / SyncEngine**：完全沿用既有演算法與 snapshot/diff 機制。
* **多 Land 共存**：每個 Land 只要提供自己的 `State` / `ClientEvents` / `ServerEvents` / Action 集合即可，Transport 依 `landID` 路由。
* **多語言 SDK**：可從 `ActionPayload` & `EventPayload` 型別反射出 schema，自動產生 TypeScript / Kotlin / Unity 客戶端。

---

# 12. Cursor System 提示（建議）

1. 所有 Land 定義都必須透過 `@Land` 或 `Land(...)` 指定 `clientEvents` / `serverEvents`。
2. Action handler 一律使用 `Action(SomePayload.self) { ... }`，不得再集中到單一 enum。
3. Event handler 應優先使用 macro 產生的語義化 API（`OnReady`, `OnChat` ...），除非需要 `switch` 全列處理。
4. Transport 必須處理 `ActionEnvelope` 的 encode/decode 與 `AnyCodable` 回傳值。
