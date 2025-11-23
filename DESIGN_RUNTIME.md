# Runtime 結構：RealmActor + SyncEngine

> 本文檔說明 SwiftStateTree 的運行時結構


## Runtime 大致結構：RealmActor + SyncEngine

### RealmActor（概念）

```swift
actor RealmActor {
    private var state: StateTree
    private let def: RealmDefinition<StateTree>
    private let syncEngine: SyncEngine
    private let ctx: RealmContext
    
    init(definition: RealmDefinition<StateTree>, context: RealmContext) {
        self.def = definition
        self.state = StateTree()
        self.syncEngine = SyncEngine()
        self.ctx = context
    }
    
    // 處理 RPC（Client -> Server）
    func handleRPC(_ rpc: GameRPC, from player: PlayerID) async -> RPCResponse {
        // 從 def.nodes 找 RPCNode<GameRPC>，執行 handler
        guard let rpcNode = findRPCNode(rpc) else {
            return .failure("Unknown RPC type")
        }
        return await rpcNode.handler(&state, rpc, ctx)
    }
    
    // 處理 Event（雙向）
    func handleEvent(_ event: GameEvent, from player: PlayerID?) async {
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
            await ctx.sendEvent(.stateUpdate(snapshot), to: .player(pid))
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

