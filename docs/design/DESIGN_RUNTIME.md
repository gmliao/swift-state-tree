# Runtime 結構：RealmActor + SyncEngine

> 本文檔說明 SwiftStateTree 的運行時結構
> 
> 相關文檔：
> - [DESIGN_SYNC_FIRSTSYNC.md](./DESIGN_SYNC_FIRSTSYNC.md) - 首次同步機制（First Sync）


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
            },
            syncHandler: { [weak self] in
                await self?.syncNow()
            }
        )
    }
    
    // 注意：RealmContext 是請求級別的，不是玩家級別的
    // - 每次 Action/Event 請求建立一個新的 RealmContext
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
    
    // 處理 Action（Client -> Server）
    func handleAction(
        _ action: GameAction,
        from playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID
    ) async -> ActionResult {
        // 建立 RealmContext（不暴露 Transport）
        let ctx = createContext(
            playerID: playerID,
            clientID: clientID,
            sessionID: sessionID
        )
        
        // 從 def.nodes 找 ActionHandlerNode<GameAction>，執行 handler
        guard let actionNode = findActionNode(action) else {
            return .failure("Unknown Action type")
        }
        return await actionNode.handler(&state, action, ctx)
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
    
    // ✅ 狀態變化追蹤
    private var pendingChanges: Set<String> = []  // 記錄哪些路徑有變化
    private var hasTick: Bool { def.config.tickInterval != nil }
    
    // ✅ 標記狀態變化
    func markStateChanged(_ path: String) {
        pendingChanges.insert(path)
        
        // Event-driven 模式：立即同步
        if !hasTick {
            Task {
                await syncStateChanges()
            }
        }
    }
    
    // ✅ Tick 觸發時統一同步（Tick-based 模式）
    func tick() async {
        // 1. 執行 Tick handler（如果有定義）
        if let tickHandler = def.tickHandler {
            await tickHandler(&state, createContext(...))
        }
        
        // 2. 同步所有待處理的變化
        if !pendingChanges.isEmpty {
            await syncStateChanges()
            pendingChanges.removeAll()
        }
    }
    
    // ✅ 手動強迫立即同步（Event-driven 模式或緊急情況）
    func syncNow() async {
        await syncStateChanges()
    }
    
    // ✅ 統一的狀態同步方法（自動處理所有玩家）
    private func syncStateChanges() async {
        // SyncEngine 自動：
        // 1. 找出所有需要同步的玩家
        // 2. 為每個玩家生成差異更新（分層計算 + Merge）
        // 3. 自動發送給對應的玩家
        await syncEngine.syncStateChanges(
            from: state,
            pendingPaths: pendingChanges.isEmpty ? nil : pendingChanges,
            transport: transport,
            realmID: def.id
        )
    }
    
    // ✅ 內部觸發狀態同步（舊方法，保留向後兼容）
    func syncState() async {
        await syncStateChanges()
    }
}

```

### SyncEngine（實現狀態）

**設計原則**：SyncEngine 負責狀態同步，支援完整快照和差異更新兩種模式。

> **首次同步機制**：SyncEngine 使用 First Sync 信號來告知客戶端同步引擎已啟動。
> 詳見 [DESIGN_SYNC_FIRSTSYNC.md](./DESIGN_SYNC_FIRSTSYNC.md)。

#### 實現狀態說明

- ✅ **已實現**：完整快照生成（用於 late join）
- ⏳ **計劃中**：差異更新（delta/diff）、快取機制、分層計算優化

#### 當前實現

```swift
struct SyncEngine {
    // ⏳ 計劃中：分層緩存：broadcast 部分共用，perPlayer 部分個別緩存
    // private var lastBroadcastSnapshot: BroadcastSnapshot?  // 共用部分（只存一份）
    // private var lastPerPlayerSnapshots: [PlayerID: PerPlayerSnapshot] = [:]  // 個別部分
    
    // ✅ 已實現：生成完整快照（用於 late join）
    func snapshot(for player: PlayerID, from state: State) throws -> StateSnapshot {
        // 1. 反射 / macro 生成的 Metadata：知道每個欄位的 SyncPolicy
        // 2. 逐欄位根據 policy 過濾：
        //    - serverOnly → 忽略
        //    - broadcast → 原值
        //    - perPlayer → 過濾 ownerID == player
        //    - masked/custom → 呼叫對應函式
        // 3. 組出一個 Codable 的中介 struct（或 JSON object）
        // 4. encode 成 JSON / MsgPack 等
        return StateSnapshot(...)
    }
}
```

#### 計劃實現功能

以下功能為計劃中的實現，當前尚未完成：

```swift
extension SyncEngine {
    // ⏳ 計劃中：生成差異更新（path-based diff）
    func generateDiff(
        for player: PlayerID,
        from tree: StateTree,
        onlyPaths: Set<String>? = nil  // 可選：只計算指定路徑
    ) throws -> StateUpdate {
        // 1. ✅ 先計算固定同步部分（broadcast，所有人一樣）
        let broadcastDiff = try computeBroadcastDiff(
            from: tree,
            onlyPaths: onlyPaths?.filter { isBroadcastPath($0) }
        )
        
        // 2. ✅ 再計算個別差異（perPlayer，每個人不同）
        let perPlayerDiff = try computePerPlayerDiff(
            for: player,
            from: tree,
            onlyPaths: onlyPaths?.filter { isPerPlayerPath($0) }
        )
        
        // 3. ✅ Merge 合併
        let mergedPatches = mergePatches(broadcastDiff, perPlayerDiff)
        
        // 4. 更新緩存
        updateCache(player: player, broadcast: broadcastDiff, perPlayer: perPlayerDiff)
        
        // 5. 返回差異更新
        if mergedPatches.isEmpty {
            return .noChange
        } else {
            return .diff(mergedPatches)
        }
    }
    
    // ⏳ 計劃中：計算 broadcast 部分的差異（所有人共用）
    private func computeBroadcastDiff(
        from tree: StateTree,
        onlyPaths: Set<String>?
    ) throws -> [StatePatch] {
        // 1. 生成當前 broadcast 快照
        let currentBroadcast = try extractBroadcastSnapshot(from: tree)
        
        // 2. 取得緩存的上次 broadcast 快照
        guard let lastBroadcast = lastBroadcastSnapshot else {
            // 第一次：緩存並返回完整快照標記
            lastBroadcastSnapshot = currentBroadcast
            return []  // 第一次用完整快照
        }
        
        // 3. 比較差異
        let patches = try compareSnapshots(
            from: lastBroadcast,
            to: currentBroadcast,
            onlyPaths: onlyPaths
        )
        
        // 4. 更新緩存
        lastBroadcastSnapshot = currentBroadcast
        
        return patches
    }
    
    // ⏳ 計劃中：計算 perPlayer 部分的差異（每個人不同）
    private func computePerPlayerDiff(
        for player: PlayerID,
        from tree: StateTree,
        onlyPaths: Set<String>?
    ) throws -> [StatePatch] {
        // 1. 生成當前 perPlayer 快照（根據 player 過濾）
        let currentPerPlayer = try extractPerPlayerSnapshot(for: player, from: tree)
        
        // 2. 取得緩存的上次 perPlayer 快照
        guard let lastPerPlayer = lastPerPlayerSnapshots[player] else {
            // 第一次：緩存並返回完整快照標記
            lastPerPlayerSnapshots[player] = currentPerPlayer
            return []  // 第一次用完整快照
        }
        
        // 3. 比較差異
        let patches = try compareSnapshots(
            from: lastPerPlayer,
            to: currentPerPlayer,
            onlyPaths: onlyPaths
        )
        
        // 4. 更新緩存
        lastPerPlayerSnapshots[player] = currentPerPlayer
        
        return patches
    }
    
    // ⏳ 計劃中：Merge 合併 broadcast 和 perPlayer 的差異
    private func mergePatches(
        _ broadcast: [StatePatch],
        _ perPlayer: [StatePatch]
    ) -> [StatePatch] {
        // 合併兩個 patch，去除重複
        var merged: [StatePatch] = []
        var seenPaths: Set<String> = []
        
        // 先加入 broadcast patches
        for patch in broadcast {
            if !seenPaths.contains(patch.path) {
                merged.append(patch)
                seenPaths.insert(patch.path)
            }
        }
        
        // 再加入 perPlayer patches（可能覆蓋 broadcast）
        for patch in perPlayer {
            if !seenPaths.contains(patch.path) {
                merged.append(patch)
                seenPaths.insert(patch.path)
            } else {
                // 如果路徑重複，perPlayer 優先（覆蓋 broadcast）
                if let index = merged.firstIndex(where: { $0.path == patch.path }) {
                    merged[index] = patch
                }
            }
        }
        
        return merged
    }
    
    // ⏳ 計劃中：自動同步所有變化（Tick-based 或 Event-driven）
    func syncStateChanges(
        from tree: StateTree,
        pendingPaths: Set<String>?,
        transport: GameTransport,
        realmID: String
    ) async {
        // 1. 取得所有需要同步的玩家
        let players = extractAllPlayers(from: tree)
        
        // 2. 為每個玩家生成差異更新
        for playerID in players {
            let update = try generateDiff(
                for: playerID,
                from: tree,
                onlyPaths: pendingPaths  // ✅ 只計算變化的路徑
            )
            
            // 3. 發送更新
            await sendUpdate(update, to: playerID, transport: transport, realmID: realmID)
        }
    }
    
    // ⏳ 計劃中：清理不活躍玩家的緩存
    func cleanupCache(olderThan: TimeInterval = 300) {
        let now = Date()
        // 清理 perPlayer 緩存
        // broadcast 緩存保留（所有人共用）
    }
    
    // ⏳ 計劃中：專門的 late join 方法（可選優化）
    // 目前可以透過 snapshot(for:from:) 實現，未來可針對 late join 場景進行優化
    func lateJoinSnapshot(
        for playerID: PlayerID,
        from state: State
    ) throws -> StateSnapshot {
        // 未來可加入：
        // - 確保返回完整快照（非差異）
        // - 可選的壓縮優化
        return try snapshot(for: playerID, from: state)
    }
}
```

### 差異計算優化：分層計算 + Merge

> **狀態**：⏳ 計劃中功能

**設計決策**：採用分層計算策略，先計算共用部分，再計算個別部分，最後合併。

**優勢**：
1. **效能優化**：broadcast 部分只計算一次，所有玩家共用
2. **記憶體優化**：broadcast 快照只存一份，不為每個玩家重複存儲
3. **計算效率**：只計算變化的路徑（如果指定了 `onlyPaths`）

**流程**：
```
StateTree 狀態變化
    ↓
1. 計算 broadcast 差異（所有人共用）
    ↓
2. 為每個玩家計算 perPlayer 差異（每個人不同）
    ↓
3. Merge 合併 broadcast + perPlayer
    ↓
4. 發送給對應玩家
```

**範例**：
```swift
// StateTree
@Sync(.broadcast)
var players: [PlayerID: PlayerState] = [:]  // 所有人看到相同

@Sync(.perPlayer(\.ownerID))
var hands: [PlayerID: HandState] = [:]      // 每個人看到不同

// 差異計算：
// 1. broadcast 差異：players.B.hpCurrent: 100 → 90（只計算一次）
// 2. perPlayer 差異：
//    - 玩家 A：hands.A.cards: [...]（只看到自己的）
//    - 玩家 B：hands.B.cards: [...]（只看到自己的）
// 3. Merge：
//    - 玩家 A：{ players.B.hpCurrent: 90, hands.A.cards: [...] }
//    - 玩家 B：{ players.B.hpCurrent: 90, hands.B.cards: [...] }
```

---

