# Runtime 結構：RealmActor + SyncEngine

> 本文檔說明 SwiftStateTree 的運行時結構


## Runtime 大致結構：RealmActor + SyncEngine

### RealmActor（概念）

**設計原則**：RealmActor 負責處理 Transport 細節，但不暴露給 StateTree 層。

```swift
actor RealmActor {
    private var state: StateTree
    private let def: RealmDefinition<StateTree>
    private let syncEngine: SyncEngine
    private let transport: GameTransport  // ✅ Transport 只在 Runtime 層
    private let services: RealmServices
    
    init(
        definition: RealmDefinition<StateTree>,
        transport: GameTransport,
        services: RealmServices
    ) {
        self.def = definition
        self.state = StateTree()
        self.syncEngine = SyncEngine()
        self.transport = transport
        self.services = services
    }
    
    // ✅ 建立 RealmContext（不暴露 Transport）
    // 注意：每次請求都建立一個新的 RealmContext（類似 NestJS Request Context）
    private func createContext(
        playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID
    ) -> RealmContext {
        RealmContext(
            realmID: def.id,
            playerID: playerID,
            clientID: clientID,
            sessionID: sessionID,
            services: services,
            // ✅ 透過閉包委派，不暴露 Transport
            sendEventHandler: { [weak self] event, target in
                await self?.sendEventInternal(event, to: target)
            }
        )
    }
    
    // 注意：RealmContext 是請求級別的，不是玩家級別的
    // - 每次 RPC/Event 請求建立一個新的 RealmContext
    // - 處理完成後釋放，不持久化
    // - 類似 NestJS 的 Request Context 設計模式
    
    // ✅ 內部方法處理 Transport 細節
    private func sendEventInternal(_ event: GameEvent, to target: EventTarget) async {
        switch target {
        case .all:
            await transport.broadcast(event, in: def.id)
        case .player(let id):
            await transport.send(event, to: id, in: def.id)
        case .client(let clientID):
            await transport.send(event, to: clientID, in: def.id)
        case .session(let sessionID):
            await transport.send(event, to: sessionID, in: def.id)
        case .players(let ids):
            for id in ids {
                await transport.send(event, to: id, in: def.id)
            }
        }
    }
    
    // 處理 RPC（Client -> Server）
    func handleRPC(
        _ rpc: GameRPC,
        from playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID
    ) async -> RPCResponse {
        // 建立 RealmContext（不暴露 Transport）
        let ctx = createContext(
            playerID: playerID,
            clientID: clientID,
            sessionID: sessionID
        )
        
        // 從 def.nodes 找 RPCNode<GameRPC>，執行 handler
        guard let rpcNode = findRPCNode(rpc) else {
            return .failure("Unknown RPC type")
        }
        return await rpcNode.handler(&state, rpc, ctx)
    }
    
    // 處理 Event（雙向）
    func handleEvent(
        _ event: GameEvent,
        from playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID
    ) async {
        // 建立 RealmContext（不暴露 Transport）
        let ctx = createContext(
            playerID: playerID,
            clientID: clientID,
            sessionID: sessionID
        )
        
        // 從 def.nodes 找 OnEventNode<GameEvent>，執行 handler
        guard let eventNode = findEventNode(event) else {
            return  // 未知的 Event 類型，忽略
        }
        await eventNode.handler(&state, event, ctx)
    }
    
    // 內部觸發狀態同步（例如 Tick 或狀態變化後）
    func syncState() async {
        let players = Array(state.players.keys)
        for pid in players {
            let snapshot = try syncEngine.snapshot(for: pid, from: state)
            // 發送給該 playerID 的所有連接
            await transport.send(
                .fromServer(.stateUpdate(snapshot)),
                to: pid,
                in: def.id
            )
        }
    }
}

```

### SyncEngine（概念）

```swift
struct SyncEngine {
    func snapshot(for player: PlayerID, from tree: StateTree) throws -> Data {
        // 1. 反射 / macro 生成的 Metadata：知道每個欄位的 SyncPolicy
        // 2. 逐欄位根據 policy 過濾：
        //    - serverOnly → 忽略
        //    - broadcast → 原值
        //    - perPlayer → 過濾 ownerID == player
        //    - masked/custom → 呼叫對應函式
        // 3. 組出一個 Codable 的中介 struct（或 JSON object）
        // 4. encode 成 JSON / MsgPack 等
        Data()
    }
}
```

---

