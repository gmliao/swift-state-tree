# 通訊模式：RPC 與 Event

> 本文檔說明 SwiftStateTree 的通訊模式設計

## 兩種通訊模式

系統採用兩種通訊模式，各自有不同的語義和用途：

### 1. RPC（Client -> Server only，有 Response）

**用途**：需要立即回饋的操作
- 查詢操作（取得手牌、驗證是否可攻擊）
- 需要驗證的狀態修改（加入房間、抽卡）
- 需要結果的操作（drawCard 需要知道抽到哪張卡）

**特點**：
- **單向**：只有 Client 可以發起 RPC 給 Server
- **有 Response**：Server 必須回傳結果
- **等待回應**：Client 發送後會等待 Server 回應
- **可選包含狀態**：Response 可以包含完整的狀態快照（用於 late join）

**範例**：

```swift
// Client 發起 RPC
let result = try await client.rpc(.join(playerID: id, name: "Alice"))
// result: JoinResponse { success: Bool, realmID: String, state: StateSnapshot? }

// Server 處理 RPC
func handle(_ rpc: GameRPC, from player: PlayerID) async -> RPCResponse {
    switch rpc {
    case .join(let id, let name):
        state.players[id] = PlayerState(...)
        let snapshot = syncEngine.snapshot(for: id, from: state)
        return .success(JoinResponse(realmID: realmID, state: snapshot))
    }
}
```

### 2. Event（雙向，無 Response）

**用途**：通知、推送，不需要立即回應
- 狀態同步推送（Server -> Client）
- 遊戲事件（傷害、特效等）
- 系統訊息（Server -> Client）
- UI 事件通知（Client -> Server）
- 心跳（Client -> Server）

**特點**：
- **雙向**：Client 和 Server 都可以發送 Event
- **無 Response**：發送方不等待回應（fire-and-forget）
- **非阻塞**：接收方異步處理，不影響其他操作

**範例**：

```swift
// Client -> Server Event（必須是在 AllowedClientEvents 中定義的 ClientEvent）
client.sendEvent(.fromClient(.playerReady(playerID: id)))
client.sendEvent(.fromClient(.heartbeat(timestamp: now)))
client.sendEvent(.fromClient(.uiInteraction(playerID: id, action: "button_clicked")))

// Server -> Client Event（Server 可以自由發送，不受限制）
server.sendEvent(.fromServer(.stateUpdate(snapshot)))
server.sendEvent(.fromServer(.gameEvent(.damage(from: attacker, to: target))))
server.sendEvent(.fromServer(.systemMessage("Game started")))
```

## RPC Response 設計

RPC Response 可以選擇性包含狀態快照，用於特殊場景：

### 包含狀態的場景

```swift
// Late Join：新加入的玩家需要完整狀態
case .join(let id, let name):
    state.players[id] = PlayerState(...)
    let snapshot = syncEngine.snapshot(for: id, from: state)
    return .success(JoinResponse(realmID: realmID, state: snapshot))  // 包含狀態

// 抽卡：需要立即知道抽到的卡
case .drawCard(let id):
    let card = state.deck.popLast()!
    state.hands[id]?.cards.append(card)
    return .success(DrawCardResponse(card: card, state: snapshot))  // 可選包含狀態
```

### 不包含狀態的場景

```swift
// 查詢操作：只需要查詢結果
case .getPlayerHand(let id):
    return .success(GetHandResponse(cards: state.hands[id]?.cards ?? []))  // 不包含狀態

// 簡單修改：狀態變化透過 Event 推送
case .attack(let attacker, let target, let damage):
    // 修改狀態
    state.players[target]?.hpCurrent -= damage
    // 推送 Event（包含狀態更新）
    await ctx.sendEvent(.stateUpdate(snapshot), to: .all)
    // Response 只返回成功/失敗
    return .success(AttackResponse(success: true))
```

## 統一使用 WebSocket 傳輸

**設計決策**：RPC 和 Event 都透過 WebSocket 傳輸，統一訊息格式

- **統一傳輸層**：所有通訊都透過 WebSocket，不需要混合 HTTP 和 WebSocket
- **訊息格式**：使用統一的 `TransportMessage` 格式來區分 RPC 和 Event
- **路由機制**：透過 `realmID` 路由到對應的 Realm，在 Transport 層處理

### 統一的傳輸訊息格式

```swift
// 統一的傳輸訊息格式（透過 WebSocket 傳輸）
enum TransportMessage: Codable {
    // RPC 請求（Client -> Server）
    case rpc(requestID: String, realmID: String, rpc: GameRPC)
    
    // RPC 回應（Server -> Client）
    case rpcResponse(requestID: String, response: RPCResponse)
    
    // Event（雙向）
    case event(realmID: String, event: GameEvent)
}

// Client 發送 RPC
let message = TransportMessage.rpc(
    requestID: UUID().uuidString,
    realmID: "match-3",
    rpc: .join(playerID: id, name: "Alice")
)
await websocket.send(message)

// Server 回應 RPC
let response = TransportMessage.rpcResponse(
    requestID: requestID,
    response: .success(.joinResult(...))
)
await websocket.send(response)

// Server 推送 Event
let event = TransportMessage.event(
    realmID: "match-3",
    event: .fromServer(.stateUpdate(snapshot))
)
await websocket.send(event)
```

### 路由機制

**設計決策**：所有 Realm 共用統一的 WebSocket 路由，透過訊息中的 `realmID` 進行路由

**優勢**：
- **簡化配置**：不需要為每個 realm 配置不同的路由
- **客戶端更簡單**：只需要連接到一個 WebSocket endpoint
- **更靈活**：可以動態加入新的 realm，不需要修改路由配置
- **符合微服務架構**：單一入口點

路由在 Transport 層處理，而不是在 Realm 定義中：

```swift
// ✅ 推薦：統一 WebSocket 路由
func configure(_ app: Application) throws {
    // 1. 定義多個 Realm（不包含網路細節）
    let matchRealm = Realm("match-3", using: GameStateTree.self) { ... }
    let gameRealm = Realm("game-room", using: GameRoomStateTree.self) { ... }
    let lobbyRealm = Realm("lobby", using: LobbyStateTree.self) { ... }
    
    // 2. 設定 Transport（不需要 routing 配置）
    let transport = WebSocketTransport(
        baseURL: "wss://api.example.com"
        // 不需要 routing 配置，因為訊息中已包含 realmID
    )
    
    // 3. 註冊所有 Realm
    await transport.register(matchRealm)
    await transport.register(gameRealm)
    await transport.register(lobbyRealm)
    
    // 4. 設定統一的 WebSocket 路由（三層識別）
    app.webSocket("ws", ":playerID", ":clientID") { req, ws in
        guard let playerIDRaw = req.parameters.get("playerID"),
              let clientIDRaw = req.parameters.get("clientID") else {
            ws.close(promise: nil)
            return
        }
        
        let playerID = PlayerID(playerIDRaw)
        let clientID = ClientID(clientIDRaw)  // 應用端提供
        let sessionID = SessionID(UUID().uuidString)  // Server 自動生成
        
        // 所有 realm 共用同一個 WebSocket 連接
        // realmID 在訊息中指定（TransportMessage 包含 realmID）
        await transport.handleConnection(
            playerID: playerID,
            clientID: clientID,
            sessionID: sessionID,
            websocket: ws
        )
    }
}
```

**訊息流程**：

```swift
// Client 連接到統一的 WebSocket endpoint（帶上 playerID 和 clientID）
let clientID = generateOrGetClientID()  // 應用端生成
let ws = await connect("wss://api.example.com/ws/player-123/\(clientID)")

// Client 發送訊息時指定 realmID
let message = TransportMessage.rpc(
    requestID: UUID().uuidString,
    realmID: "match-3",  // 在訊息中指定 realm
    rpc: .join(playerID: id, name: "Alice")
)
await ws.send(message)

// Transport 層根據訊息中的 realmID 路由
// handleMessage 中：realmActors[realmID] 找到對應的 RealmActor
```

**設計要點**：
1. **訊息層級路由**：`realmID` 在 `TransportMessage` 中，而非 URL 路徑
2. **Transport 層處理**：根據 `realmID` 查找對應的 `RealmActor`
3. **三層識別**：`playerID`（帳號）+ `clientID`（裝置）+ `sessionID`（會話）
4. **多連接支援**：同一個 `playerID` 可以有多個 `clientID`（多裝置），同一個 `clientID` 可以有多個 `sessionID`（多標籤頁）
5. **動態加入**：新 realm 只需註冊，不需要修改路由配置
6. **WebSocket 不暴露**：StateTree/Realm 層不知道 WebSocket 的存在，透過 RealmContext 抽象

**可選：分離路由**（特殊場景）

如果需要，仍可為特定 realm 使用獨立路由（例如隔離或效能考量），但統一路由是推薦的預設方式。

## Event 處理範圍

**設計決策**：採用 **選項 C（Realm DSL 中定義）**

- `AllowedClientEvents` **只限制 Client->Server 的 Event**（`ClientEvent`）
- **Server->Client 的 Event 不受限制**（`ServerEvent`，因為是 Server 自己控制的）
- 在 Realm DSL 中使用 `AllowedClientEvents` 定義允許的 `ClientEvent`

### ClientEvent 分類

1. **遊戲邏輯 Event**（Server 需要處理並可能修改狀態）
   - `.playerReady(playerID)`: 玩家準備
   - `.playerAction(playerID, action)`: 玩家動作

2. **通知類 Event**（Server 只記錄，不修改狀態）
   - `.heartbeat(timestamp)`: 心跳
   - `.uiInteraction(playerID, action)`: UI 事件（用於分析）

### ServerEvent 分類

Server 可以自由定義和發送 ServerEvent（不受 AllowedClientEvents 限制）：
- `.stateUpdate(snapshot)`: 狀態更新
- `.gameEvent(GameEventDetail)`: 遊戲事件
- `.systemMessage(String)`: 系統訊息

