# 效能優化計劃

> 本文檔記錄 SwiftStateTree 的後續效能優化計劃和設計方向

## 概述

目前 SwiftStateTree 已經實現了基本的同步機制和 diff 計算，**並支援遞迴過濾功能**（巢狀 StateNode 可以獨立套用 @Sync 政策）。

**重要說明**：遞迴過濾已經解決了以下問題：
- ✅ **細粒度過濾**：不需要 ReactiveDictionary，可以用 StateNode 來細分
- ✅ **Per-Player 細分**：不需要 Per-Player State View 架構，遞迴過濾已經可以做到

為了進一步提升效能，特別是針對大型狀態樹和高頻更新場景，我們計劃實施以下優化策略。

---

## 架構層級效能比較：舊 OOP 架構 vs 新 StateTree 架構

> 本章節說明傳統「物件導向 + 全局容器」式伺服器架構與新「StateTree（struct）+ actor + snapshot/diff + TaskGroup」架構的效能差異、並行模型、資料擁有權、可擴展性等核心差別。

### 1. 舊架構的典型模式與效能瓶頸

傳統多人遊戲伺服器常使用下列設計：

```swift
// 傳統 OOP 架構範例
class Player {
    var hp: Int
    var position: Vec2
    // ...
}

class Monster {
    var hp: Int
    var position: Vec2
    // ...
}

class EntityManager {
    var objects: Map<EntityID, BaseEntity>
    
    func updateAll() {
        // 遍歷所有 entity，更新狀態
        // 同時處理同步、廣播、AOI 計算
    }
}
```

**典型特徵**：
- 每個物件一個 class
- 全局容器（EntityManager / World）
- 各物件 methods 裡同時包含資料更新 + 效果觸發 + 廣播 + 計算
- AOI 可見度邏輯、同步邏輯分散在不同位置
- Dirty flag 追蹤分散在各個物件中

#### 效能與可擴展性的問題

**1. Pointer Chasing 導致 Cache Miss 嚴重**

每次 tick 需遍歷大量 entity（class），CPU 無法預先載入資料。記憶體布局分散，cache locality 差。

**2. 邏輯與狀態耦合 → 很難多執行緒化**

物件 methods 內常常：
- 改自己
- 改別人
- 發 event
- 更新 container

導致必須鎖住整個世界，幾乎只能依賴「單一主線程」執行遊戲邏輯。

**3. Diff / AOI / patch 組裝無法並行化**

因為資料一直變、邏輯纏在一起，不能安全丟多執行緒處理。

**4. 想多執行緒，只能把某些小系統獨立出去**

例如：
- 將 AOI 獨立成 worker thread
- 但核心的「狀態 → patch」流程仍然是單線程瓶頸

**結論**：舊架構的效能天花板通常被「單線程」綁死。大房間（>50 玩家）、重狀態、10Hz tick → 容易 CPU 爆掉。

---

### 2. SwiftStateTree 新架構的結構性突破

新架構基於：
- **StateTree**（struct、value semantics）
- **LandKeeper**（唯一可變的 actor）
- **snapshot / diff engine**
- **TaskGroup** 並行 pure-computation
- **@Sync DSL** 宣告同步策略

讓你得到一個「資料所有權清晰＋計算天然可並行」的執行模型。

#### 2.1 狀態：集中成一棵「可序列化的大 struct」

```swift
@StateTree
struct RoomState {
    @Sync(.broadcast) var world: WorldState
    @Sync(.perPlayer{...}) var players: [PlayerID: PlayerState]
    @Sync(.masked) var monsters: [MonsterID: MonsterState]
}
```

**優勢**：
- 統一狀態模型
- 相對集中、cache friendly
- snapshot 是不可變的值（或 ARC-shared immutable graph）

#### 2.2 修改權限集中：只有 actor 能修改 RoomState

```swift
actor LandKeeper {
    var state: RoomState
    
    func tick() {
        // 修改 state 的唯一入口
    }
}
```

避免並行 data race。

#### 2.3 snapshot → TaskGroup → diff → patch：完美分工

**流程**：
1. 抽 snapshot（在 actor 內、極短時間 lock）
2. 離開 actor 後，所有計算皆為「純函式」
3. TaskGroup 並行化計算 per-player diff / AOI / patch

```swift
await withTaskGroup { group in
    for player in players {
        group.addTask {
            computePlayerPatch(snapshot, player)
        }
    }
}
```

這段是最吃 CPU 的部分，也是可以利用多核的地方。

---

### 3. 雙層並行模型：效能倍數提升的來源

架構天然具備「兩層並行」：

#### 3.1 第一層：多房間 → 多 actor → 多核分散

- 每房一個 `LandKeeper` actor
- Swift runtime 自然將不同 actor 的工作排到不同 thread

**效果**：總 CCU（整機玩家數）提升數倍，不互相阻塞。

#### 3.2 第二層：房內 pure computation → TaskGroup 並行化

每個房間在 tick 時：
- diff
- AOI
- per-player masking
- patch 組裝

全部都可以拆成 N 個玩家的 N 個獨立工作，丟給 TaskGroup：

**單一房間可容納玩家數，理論上可達多核心加速倍率（2～6 倍）**。

#### 3.3 雙層加乘（不是相加，是乘法）

**範例**：
- 舊架構：單房 80 人、8 房 → 640 人
- 新架構（房內 3× 加速）：單房 240 人、8 房 → 1920 人

👉 **整機容量直接變成 3 倍以上**

真正差距不是「微調級」，是一個等級級別。

---

### 4. 為什麼新架構比舊架構「快很多」？

以下是效能差距可能達到 **3～10×** 的主要原因：

#### A. Struct + 整棵 StateTree = Cache 效益比 class pointer 大數倍

- 遞迴地比對 struct → 線性掃描記憶體非常快
- 舊架構 pointer chasing → cache miss 超多

#### B. snapshot/diff 設計本質是 pure function → 可完美並行

舊架構狀態 mutate 與計算糾纏，無法安全並行。

新架構 snapshot 是「不可變」、「只讀」→ 可以丟 N 個 Task 並行。

#### C. actor 把「可變」與「不可變」分界切得非常乾淨

舊架構需要大量鎖、或根本不敢開 thread。

新架構：
- actor 保護 mutate
- TaskGroup 保證 pure compute 可以任意平行

==> **多核吃滿的必要條件具備了**

#### D. @Sync DSL 把同步、mask、perPlayer 遞迴策略集中宣告

舊架構：同步邏輯散在 handler / class method / event bus 四處。

新架構：宣告一次 → diff engine 自動處理 → 防錯 + 快速 + 結構一致。

#### E. 設計就是為了多線程，不是「事後再補」

新設計具備：
- 寫法簡單（業務邏輯不用管並行）
- 並行無 race condition（因為資料不可變）
- 真正 CPU-heavy 部分全部可 TaskGroup 化

這是一開始就為多線程而寫的設計。

不像舊架構是：想多線程 → 卡在資料耦合 → 卡在鎖 → 卡在 race → 最後放棄

---

### 5. Tick 是否需要刻意「岔開」？（房間多的情況）

**簡單答案**：大量房間時，tick 稍微錯開會比較平滑，但不是必須。

#### 可選做法

**方式 1：每房初始化時給一個 random phase**

```swift
let baseInterval = 100.ms
let phase = random(in: 0..<baseInterval)

func loop() async {
    try await Task.sleep(for: phase)
    while true {
        await tick()
        try await Task.sleep(for: baseInterval)
    }
}
```

**效果**：每個房間 tick 的時間不一樣（有點像交錯），整體 CPU / 網路負載比較「平滑」，沒有巨大尖峰。

**方式 2：由 scheduler 做 round-robin**

```swift
actor RoomScheduler {
    var rooms: [LandKeeper] = []
    
    func runLoop() async {
        let interval = 100.ms
        while true {
            let frameStart = now()
            for room in rooms {
                await room.tickIfDue(now: frameStart)
            }
            // 自己控制 sleep / 誤差
        }
    }
}
```

讓每一 frame 不是所有房間都一定 tick，可能這 frame tick 一半房間，下個 frame tick 另一半。

#### 建議

- **小規模（<=50 房）**：通常沒必要
- **大規模（>500 房）**：建議採用

**實作建議**：
1. API 設計上保留「房間自己控制 tick」的彈性（例如 `LandKeeper.startTickLoop(interval:phase:)`）
2. 先做最直覺簡單版（例如每房 `Task.sleep(interval)`）
3. 真正壓測、房間數量變多時，再加「隨機 phase」就好了

不需要一開始就搞得很複雜，但設計上要知道「之後可以這樣優化」。

---

### 6. 最終結論

舊的 OOP（每物件一個 class + 全局容器）架構，受限於資料分散、邏輯糾纏、共享 mutable state，理論上只能靠單線程執行核心遊戲邏輯。在大房間 / 大狀態 / 固定 tick 中，容易出現 CPU 瓶頸。

**SwiftStateTree 架構透過**：
- StateTree struct（集中資料、cache friendly）
- actor（唯一可變點）
- snapshot / diff（pure computation）
- TaskGroup（可安全平行化）
- @Sync DSL（宣告同步策略）

將狀態與計算完全分離，讓整個世界模型天然可拆成多個 Task。

**因此同時具備**：
- 單房 CPU-bound 計算可達多倍提升（2～6×）
- 多房間可完整利用多核心（整機 CCU 提升數倍）
- 整體吞吐量呈倍數成長（3～10×，視 workload 而定）

**這是結構級別的效能優勢，不是微調級的優化。**

---

### 7. 效能提升的理論分析

#### 單核心上的純計算效率

- **舊**：pointer 物件 + 處理流程四散 + branch 混雜
- **新**：struct 樹 + 資料相對集中 + 演算法更明確（diff / AOI / 遞迴）

在大量 entity / 大量狀態的情況下：**單核純計算，有機會快個 1.5～3 倍是合理的**。

#### 多核心的吃法

- **舊**：幾乎只能 1 條主線程 + 一點 I/O / AOI 分出去，要再切更多會開始撞鎖 / 撞 shared state
- **新**：
  - 多房間 → 多 actor 自然分散多核
  - 單一房間內 → diff / AOI / per-player patch 用 TaskGroup 撐滿多核

如果你有 8 核：理論上 CPU-bound 的那一塊，可以拿到接近 **4～6x 的 speedup**（扣掉排程開銷後）。

#### 混在一起的「整體感受」

整體來看，在「大房 / 多玩家 / 大狀態 / 固定頻率 tick」的遊戲場景：

- **舊架構**：單線程那條 loop 先爆，CPU 一顆吃滿，其他核心很閒
- **新 StateTree 架構**：
  - 單核上算法本來就比較快
  - 再加上可以平行化
  - 全機 CPU 真的有機會都被用來幫你算「diff + AOI + patch」

**保守估計**：在你那種「多人房、狀態體積大、固定 tick」的場景，從舊架構換到「StateTree + actor + diff + TaskGroup」這套，理論上拿到 **3～10 倍的效能提升是合理期待的範圍**。

當然：
- 真的是 3 倍、5 倍、還是 8 倍 → 要看你的 AOI、狀態結構、tick 頻率
- 但絕對不是只在那邊吵 10% 的微調級

---

### 8. 安全性與可維護性的額外優勢

除了效能，新架構還順便解掉以前多執行緒最痛的兩個點：

**1. 誰可以改 state？**
- 現在答案超清楚：只有 actor 裡可以改。

**2. 可以並行的是哪一段？**
- 離開 actor、用 snapshot 的那一大段全部都可以平行。

**對比**：
- **以前**：還沒想清楚所有權、就先亂多執行緒，之後一年都在 debug race condition
- **現在**：架構一開始就先把可變 / 不可變切乾淨，多執行緒只是「多開 Task 跑純計算」，穩定很多

---

## 優化目標

1. **減少不必要的計算**：只處理真正改變的欄位
2. **細粒度追蹤**：支援 per-player 層級的細粒度變更追蹤
3. **容器優化**：針對 Dictionary、Set 等容器的特殊優化
4. **自動化**：減少手動標記的需求，自動偵測變更

---

## 已完成的優化與量測結果（2024-XX-XX）

- **Dirty Tracking 分流**：`generateDiff` 依 `getSyncFields()` 將 dirty 欄位拆成 broadcast/per-player，分別序列化並比較。dirty 為空時，per-player 路徑直接返回，避免無效序列化。
- **序列化快路**：
  - `SnapshotValue.make` 對 `SnapshotValue` / `StateSnapshot` 直接短路，繞過動態 cast。
  - 增加常見字典快路（`[PlayerID: SnapshotValue]` / `[PlayerID: SnapshotValueConvertible]` / `[PlayerID: StateNodeProtocol]` / `[String: SnapshotValueConvertible]`）以避免 Mirror。
  - benchmark 型別盡量使用 macro 產生的 typed 序列化，降低 Any/Mirror 負擔。
- **實際效能（單核心、100 iterations，DiffBenchmarkRunner）：**
  - Tiny (5 players, 3 cards)：標準 0.378ms → 優化 0.154ms，**2.45x**。
  - Small (10 players, 5 cards)：標準 0.306ms → 優化 0.167ms，**1.83x**。
  - Medium (100 players, 10 cards)：標準 1.768ms → 優化 0.935ms，**1.89x**。

> 總體：單核心每秒可處理 ~1–6k 次 diff，視狀態大小而定。

## 後續優化：Snapshot 一致性與提取策略

- **一致性保障**：`computeBroadcastDiff` / `computePerPlayerDiff` 需要與 cache 比較的同一版本快照。外層應以 lock/actor 包裹「讀 state → 拷貝/凍結 → 解鎖 → diff」流程，避免計算中途 state 被改。
- **值語義拷貝**：`StateNode` 為 struct 時，可在鎖內 `var snapshot = state` 後解鎖計算；需確保欄位是值語義或 COW（標準 `Array`/`Dictionary`/`Set` 可用），若元素含 class 或非 COW 型別則要深拷。
- **統一提取快照**：考慮新增 API 讓呼叫端一次產出 broadcast / per-player 快照（dirty/all 模式）後傳入 diff，減少重複序列化並保證同一 state 版本；diff 內仍需保持首次呼叫時用 `.all` 補全 cache 的行為。
- **型別規範**：在 `StateNode` 模型層要求欄位為值語義 + `Sendable`，必要時以自訂 COW wrapper 或 lint/SwiftSyntax 規則禁止引用型別進入狀態，避免拷貝後仍共享底層資料。
- **啟動預熱**：可在 Land/伺服器啟動時先鎖定 state 並生成一次 broadcast/per-player baseline（或至少 broadcast），填入 cache，降低第一位玩家觸發全量 snapshot 的延遲。
  - 預熱時機要在初始狀態「打理完」後再做，避免把半成品寫進 cache，導致第一個 diff 回傳大批「開門前打掃」的 patch。

### 已實作的 API（2024-XX-XX）

以下優化項目已經實作並可用：

#### 1. 統一快照提取 API

**API**：
- `SyncEngine.extractBroadcastSnapshot(from:mode:)` - 提取 broadcast 快照（所有玩家共用，只需提取一次）
- `SyncEngine.extractPerPlayerSnapshot(for:from:mode:)` - 提取 per-player 快照（每個玩家不同）

**重要設計**：
- **Broadcast 快照是共用的**：所有玩家看到相同的 broadcast 欄位，只需提取一次即可重用
- **Per-player 快照是獨立的**：每個玩家有不同的 per-player 欄位，需要分別提取

**推薦使用方式**（多玩家場景）：
```swift
// 在 actor 或鎖內：
// 1. 提取一次 broadcast（所有玩家共用）
let broadcastSnapshot = try syncEngine.extractBroadcastSnapshot(from: state)

// 2. 為每個玩家分別提取 per-player
for playerID in allPlayerIDs {
    let perPlayerSnapshot = try syncEngine.extractPerPlayerSnapshot(for: playerID, from: state)
    
    // 3. 解鎖後計算 diff
    let update = try syncEngine.generateDiffFromSnapshots(
        for: playerID,
        broadcastSnapshot: broadcastSnapshot,  // 共用同一個 broadcast
        perPlayerSnapshot: perPlayerSnapshot
    )
}
```

**單玩家場景**：
```swift
// 即使只有一個玩家，也推薦分別提取（保持一致性）
let broadcastSnapshot = try syncEngine.extractBroadcastSnapshot(from: state)
let perPlayerSnapshot = try syncEngine.extractPerPlayerSnapshot(for: playerID, from: state)
```

**優點**：
- 減少重複序列化（broadcast 只需提取一次）
- 保證一致性（broadcast 和 per-player 快照來自同一 state 版本）
- 支援 dirty tracking 模式（透過 `mode` 參數）

#### 2. 一致性保障 API

**API**：`SyncEngine.generateDiffFromSnapshots(for:broadcastSnapshot:perPlayerSnapshot:onlyPaths:mode:)`

使用預提取的快照計算 diff，允許外層鎖定 state、提取快照、解鎖後再計算 diff。

**使用模式**（外層需實作）：

**單玩家場景**：
```swift
// 在 LandKeeper 或類似的外層：
actor LandKeeper {
    private var state: GameState
    private var syncEngine: SyncEngine
    
    func syncForPlayer(_ playerID: PlayerID) async throws -> StateUpdate {
        // 1. 在 actor 內鎖定 state 並提取快照
        let broadcastSnapshot = try syncEngine.extractBroadcastSnapshot(from: state)
        let perPlayerSnapshot = try syncEngine.extractPerPlayerSnapshot(for: playerID, from: state)
        
        // 2. 解鎖後再計算 diff（避免長時間持有鎖）
        return try syncEngine.generateDiffFromSnapshots(
            for: playerID,
            broadcastSnapshot: broadcastSnapshot,
            perPlayerSnapshot: perPlayerSnapshot
        )
    }
}
```

**多玩家場景**（推薦，效能更好）：
```swift
actor LandKeeper {
    private var state: GameState
    private var syncEngine: SyncEngine
    
    func syncForAllPlayers(_ playerIDs: [PlayerID]) async throws -> [PlayerID: StateUpdate] {
        // 1. 在 actor 內鎖定 state，提取一次 broadcast（所有玩家共用）
        let broadcastSnapshot = try syncEngine.extractBroadcastSnapshot(from: state)
        
        // 2. 為每個玩家提取 per-player 快照
        var perPlayerSnapshots: [PlayerID: StateSnapshot] = [:]
        for playerID in playerIDs {
            perPlayerSnapshots[playerID] = try syncEngine.extractPerPlayerSnapshot(for: playerID, from: state)
        }
        
        // 3. 解鎖後再計算 diff（避免長時間持有鎖）
        var updates: [PlayerID: StateUpdate] = [:]
        for playerID in playerIDs {
            updates[playerID] = try syncEngine.generateDiffFromSnapshots(
                for: playerID,
                broadcastSnapshot: broadcastSnapshot,  // 共用同一個 broadcast
                perPlayerSnapshot: perPlayerSnapshots[playerID]!
            )
        }
        return updates
    }
}
```

**優點**：
- 確保 `computeBroadcastDiff` 和 `computePerPlayerDiff` 使用同一版本的快照
- 允許外層控制鎖定時機，減少鎖持有時間
- 與現有 `generateDiff` API 完全相容（可選擇性使用）

#### 3. 啟動預熱 API

**API**：`SyncEngine.warmupCache(from:)`

在 Land/伺服器啟動時預熱 broadcast cache，降低第一位玩家觸發全量 snapshot 的延遲。

```swift
// 在初始狀態完全設置完成後調用
try syncEngine.warmupCache(from: initialState)
```

**實作細節**：
- 如果 broadcast cache 已存在，跳過（避免覆蓋）
- 生成 broadcast snapshot 並存入 cache（所有玩家共用）
- **不預熱 per-player cache**：per-player cache 會在玩家第一次調用 `generateDiff` 時自動建立
- 確保預熱時機在初始狀態「打理完」後（由外層控制）

**設計理由**：
- Broadcast cache 是所有玩家共用的，在啟動時就可以預熱
- Per-player cache 是每個玩家獨立的，在啟動時：
  - 可能還沒有玩家加入
  - 不知道哪些玩家會加入
  - 應該在玩家實際加入時（第一次調用 `generateDiff`）才建立

**注意事項**：
- ⚠️ **預熱時機很重要**：必須在初始狀態完全初始化後調用，避免把半成品寫進 cache
- 如果預熱時機過早，第一個 diff 會回傳大批「開門前打掃」的 patch

#### 4. 值語義拷貝策略

**設計原則**：

由於 `StateNode` 為 `struct`（值語義），可以在鎖內進行值拷貝後解鎖計算：

```swift
// 在 actor 或鎖內：
var snapshot = state  // 值語義拷貝（struct copy）
// 解鎖後再使用 snapshot 計算 diff
```

**要求**：
- ✅ **值語義欄位**：標準 Swift 型別（`Int`, `String`, `Bool` 等）自動支援
- ✅ **COW 容器**：標準 `Array`/`Dictionary`/`Set` 使用 Copy-on-Write，效率高
- ⚠️ **非 COW 型別**：若欄位包含 `class` 或非 COW 型別，需要深拷貝或確保不可變

**最佳實踐**：
- 在 `StateNode` 定義中，確保所有 `@Sync` 欄位為值語義或 COW 型別
- 避免在狀態中直接使用 `class` 型別（除非是不可變的）
- 使用 `Sendable` 標記確保線程安全

## 1. isDirty 機制優化

### 目標
實現自動化的 dirty tracking，無需手動標記即可偵測狀態變更。

### 重要：必須使用系統提供的 CRUD 函數

**⚠️ 關鍵設計原則**：對於 Dictionary、Array 等集合類型，**必須使用系統提供的 CRUD 函數**或通過 `@Sync` property wrapper 的 setter 來修改，才能正確觸發 dirty tracking。

#### 正確的使用方式

```swift
@StateNodeBuilder
struct GameStateTree: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]
    
    @Sync(.broadcast)
    var round: Int = 0
}

// ✅ 正確：使用 @Sync setter（自動標記 dirty）
state.players[playerID] = PlayerState(...)  // 會觸發 @Sync setter，自動標記 players 為 dirty
state.round = 1  // 會觸發 @Sync setter，自動標記 round 為 dirty

// ❌ 錯誤：直接修改字典內容（不會觸發 dirty tracking）
// var dict = state.players  // 取得字典副本
// dict[playerID] = PlayerState(...)  // 修改副本
// state.players = dict  // 需要重新賦值才能觸發 setter
```

**為什麼必須使用系統提供的函數？**

1. **Dirty Tracking 依賴 Setter**：`@Sync` property wrapper 的 `wrappedValue` setter 會自動標記字段為 dirty
2. **直接修改不會觸發 Setter**：如果直接修改字典/數組的內部內容而不通過 setter，dirty tracking 無法檢測到變化
3. **優化版 Diff 的準確性**：優化版 diff（`useDirtyTracking: true`）只比較 dirty 字段，如果字段沒有被標記為 dirty，變化可能被忽略

**對於 ReactiveDictionary 和 ReactiveSet**

如果使用 `ReactiveDictionary` 或 `ReactiveSet`，它們內建了 dirty tracking：

```swift
@StateNodeBuilder
struct GameStateTree: StateNodeProtocol {
    @Sync(.broadcast)
    var players: ReactiveDictionary<PlayerID, PlayerState> = ReactiveDictionary()
}

// ✅ 正確：使用 ReactiveDictionary 的方法（自動標記 dirty）
state.players[playerID] = PlayerState(...)  // 自動標記 dirty
state.players.removeValue(forKey: playerID)  // 自動標記 dirty
state.players.updateValue(PlayerState(...), forKey: playerID)  // 自動標記 dirty
```

### 設計方向

#### 1.1 Property Wrapper 層級的 Dirty Tracking

在 `@Sync` property wrapper 層級自動追蹤變更：

```swift
@StateNodeBuilder
struct GameStateTree: StateTreeProtocol {
    @Sync(.broadcast)
    var round: Int = 0  // 自動追蹤變更，無需手動 markDirty
    
    @Sync(.perPlayerSlice())
    var hands: [PlayerID: HandState] = [:]  // 自動追蹤 Dictionary 變更
}
```

**實作方式**：
- 在 `@Sync` property wrapper 的 `wrappedValue` setter 中自動標記 dirty
- 使用 `willSet`/`didSet` 或 `_modify` 來攔截變更
- 維護內部 dirty 狀態，由 SyncEngine 查詢

#### 1.2 自動 Dirty 查詢 API

```swift
protocol StateTreeProtocol {
    /// 檢查是否有任何欄位被標記為 dirty
    func isDirty() -> Bool
    
    /// 檢查特定欄位是否為 dirty
    func isDirty(_ fieldName: String) -> Bool
    
    /// 檢查特定玩家的 per-player 欄位是否為 dirty
    func isDirty(_ fieldName: String, for playerID: PlayerID) -> Bool
    
    /// 取得所有 dirty 欄位名稱
    func getDirtyFields() -> Set<String>
}
```

#### 1.3 與 SyncEngine 整合

**重要設計考量**：如果 `isDirty == false` 就跳過生成欄位，會導致誤判為刪除。

**問題場景**：
```swift
// 舊快照（cache）
{
  "round": 10,
  "players": {...}
}

// 新狀態：round 沒變（isDirty = false），players 變了（isDirty = true）
// 如果只生成 dirty 欄位：
{
  "players": {...}  // 只有 players，沒有 round
}

// 比較時：
// oldSnapshot["round"] = 10
// newSnapshot["round"] = nil  // 沒有這個欄位！
// → 會被誤判為刪除！❌
```

**解決方案**：比較時需要考慮 dirty 資訊

```swift
extension SyncEngine {
    /// 使用自動 dirty tracking 生成 diff
    public mutating func generateDiff<State: StateNodeProtocol>(
        for playerID: PlayerID,
        from state: State,
        useDirtyTracking: Bool = true  // 預設啟用
    ) throws -> StateUpdate {
        if useDirtyTracking && state.isDirty() {
            // 取得 dirty 欄位資訊
            let dirtyFields = state.getDirtyFields()
            
            // 只生成 dirty 欄位的快照（減少序列化開銷）
            let dirtySnapshot = try state.snapshot(for: playerID, onlyDirty: true)
            
            // 比較時傳入 dirty 資訊，避免誤判刪除
            return try generateDiffWithDirtyTracking(
                for: playerID,
                from: state,
                dirtyFields: dirtyFields
            )
        } else {
            // 標準方式：檢查所有欄位
            return try generateDiffStandard(for: playerID, from: state)
        }
    }
    
    /// 比較時考慮 dirty 資訊，避免誤判刪除
    private func compareSnapshots(
        from oldSnapshot: StateSnapshot,
        to newSnapshot: StateSnapshot,
        dirtyFields: Set<String>,  // 新增：dirty 欄位資訊
        onlyPaths: Set<String>? = nil
    ) -> [StatePatch] {
        var patches: [StatePatch] = []
        let allKeys = Set(oldSnapshot.values.keys).union(Set(newSnapshot.values.keys))
        
        for key in allKeys {
            let oldValue = oldSnapshot.values[key]
            let newValue = newSnapshot.values[key]
            
            if oldValue != nil && newValue == nil {
                // ⚠️ 關鍵：如果這個欄位不是 dirty，視為未變更（避免誤判刪除）
                if !dirtyFields.contains(key) {
                    continue  // 跳過，視為未變更
                }
                // 如果是 dirty 且不存在，才是真正的刪除
                patches.append(StatePatch(path: "/\(key)", operation: .delete))
            } else if oldValue == nil && newValue != nil {
                // 新增
                patches.append(StatePatch(path: "/\(key)", operation: .set(newValue)))
            } else if let oldValue = oldValue, let newValue = newValue {
                // 兩個都存在，比較值（只比較 dirty 欄位）
                if dirtyFields.contains(key) {
                    patches.append(contentsOf: compareSnapshotValues(
                        from: oldValue,
                        to: newValue,
                        basePath: "/\(key)"
                    ))
                }
                // 如果不是 dirty，跳過比較
            }
        }
        
        return patches
    }
}
```

**設計原則**：
1. **只生成 dirty 欄位的快照**：減少序列化開銷
2. **比較時傳入 dirty 資訊**：避免誤判刪除
3. **只比較 dirty 欄位**：減少比較開銷

### 優點
- **零配置**：開發者無需手動標記，自動運作
- **向後相容**：可以選擇性啟用，不影響現有程式碼
- **效能提升**：
  - 只序列化 dirty 欄位（減少序列化開銷）
  - 只比較 dirty 欄位（減少比較開銷）
  - 正確處理刪除（需要 dirty 資訊）

### 挑戰
- Property wrapper 的變更攔截需要仔細設計
- 需要處理 nested 結構的變更追蹤
- **容器類型（Dictionary、Set）的變更偵測較複雜**：這是 Property Wrapper 的根本限制
  - `state.players["alice"] = "Alice"` 不會觸發 property wrapper 的 setter
   - 需要額外機制來追蹤容器內部變更（已由遞迴過濾解決）
- **避免誤判刪除**：比較時需要 dirty 資訊來區分「未變更」和「真正刪除」

---

## 2. 細粒度優化（Fine-grained Optimization）

> **注意**：遞迴過濾已經提供了細粒度控制能力。此章節主要說明如何與 dirty tracking 配合使用。

### 目標
支援更細粒度的變更追蹤，特別是針對 per-player 欄位。

### 設計方向

#### 2.1 與遞迴過濾配合的細粒度追蹤

遞迴過濾已經可以做到細分，但 dirty tracking 可以進一步減少計算：

```swift
@StateNodeBuilder
struct PlayerStateNode: StateNodeProtocol {
    @Sync(.broadcast) var position: Vec2
    @Sync(.perPlayer { ... }) var inventory: [PlayerID: [Item]]
}

@StateNodeBuilder
struct GameStateRootNode: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerStateNode] = [:]
}

// 只有 Alice 的 inventory 改變
state.players[alice].inventory[bob] = ["item1"]

// 自動標記：只有 players[alice].inventory 欄位是 dirty
// 遞迴過濾 + dirty tracking：只處理變更的部分
```

#### 2.2 Dictionary 值層級的追蹤

對於 `@Sync(.perPlayerSlice())` 欄位，追蹤到具體的 key：

```swift
@Sync(.perPlayerSlice())
var hands: [PlayerID: HandState] = [:]
 
// 內部追蹤：
// dirtyKeys: Set<PlayerID> = [alice]  // 只有 alice 的 hands 改變
```

**實作方式**：
- 在 Dictionary 的 subscript setter 中記錄變更的 key
- SyncEngine 只處理 dirty keys 對應的值
- 與遞迴過濾配合：如果值是 StateNode，會遞迴套用過濾

### 優點
- **精確追蹤**：只處理真正改變的部分
- **效能提升**：大型容器中只有小部分改變時，效能提升明顯
- **頻寬節省**：只傳輸改變的部分
- **與遞迴過濾配合**：可以做到非常細粒度的控制

### 挑戰
- 需要實作容器類型的特殊處理
- 變更偵測的實作複雜度較高

---

## 3. 容器優化（Container Optimization）

### 目標
針對 Dictionary、Set 等容器類型進行特殊優化。

### 設計方向

#### 3.1 Dictionary 優化

**問題**：當 Dictionary 只有部分 key-value 改變時，目前會比較整個 Dictionary。

**優化方案**：
- 追蹤變更的 keys
- 只比較和序列化變更的 key-value pairs
- 使用 path-based diff：`/hands/alice` 而不是 `/hands`

```swift
// 優化前：比較整個 hands Dictionary
let oldHands = lastSnapshot.values["hands"]  // 整個 Dictionary
let newHands = currentSnapshot.values["hands"]  // 整個 Dictionary
compare(oldHands, newHands)  // 比較所有 key-value pairs

// 優化後：只比較變更的 key
let dirtyKeys = state.getDirtyKeys(for: "hands")  // [alice]
for key in dirtyKeys {
    let oldValue = oldHands[key]
    let newValue = newHands[key]
    compare(oldValue, newValue)  // 只比較變更的 key
}
```

**⚠️ 重要：優化版 Diff 的 Patch 路徑層級**

當使用優化版 diff（`useDirtyTracking: true`）時，對於 Dictionary 類型的字段，可能會產生不同層級的 patch：

- **標準版**（`useDirtyTracking: false`）：
  - 遞歸比較字典內容，生成細粒度 patch：`/players/alice`
  - 只針對實際變化的 key 生成 patch

- **優化版**（`useDirtyTracking: true`）：
  - 當整個字典字段被標記為 dirty 時，**如果字典在 cache 中不存在**，會生成整個對象替換的 patch：`/players`
  - 如果字典在 cache 中存在（即使是空字典），會遞歸比較，生成細粒度 patch：`/players/alice`
  - 這是因為優化版優先考慮效能，當字段是 dirty 時，直接比較整個字段值

**兩種方式都是正確的**：
- 標準版：更細粒度，適合需要精確控制 patch 內容的場景
- 優化版：更高效，適合大型字典且大部分內容都改變的場景

**實際行為分析**：

```swift
// 場景 1：字典在 cache 中存在（即使是空字典）
// First sync: players = {}
// Second sync: players = {"alice": "Alice"}
// → 優化版會遞歸比較，生成 /players/alice 的 patch ✅

// 場景 2：字典在 cache 中不存在
// First sync: players 沒有被包含在 snapshot 中（可能是 nil 或不存在）
// Second sync: players = {"alice": "Alice"}
// → 優化版會生成 /players 的 patch（整個對象替換）✅
```

**建議**：
- 如果字典只有少量 key 改變，使用標準版可以生成更小的 patch
- 如果字典大部分內容都改變，使用優化版可以減少比較開銷
- **最佳實踐**：在第一次 sync 時明確初始化所有字典字段（即使是空字典），確保它們都在 cache 中，這樣優化版也能生成細粒度的 patch
- 實際使用中，兩種方式都能正確同步狀態，選擇取決於效能需求

#### 3.2 Set 優化

**問題**：Set 的變更需要知道新增和刪除的元素。

**優化方案**：
- 追蹤新增和刪除的元素
- 使用 set difference 來計算變更

```swift
let oldSet: Set<PlayerID> = lastSnapshot.values["readyPlayers"]
let newSet: Set<PlayerID> = currentSnapshot.values["readyPlayers"]

let added = newSet.subtracting(oldSet)  // 新增的元素
let removed = oldSet.subtracting(newSet)  // 刪除的元素

// 生成 patches
for playerID in added {
    patches.append(StatePatch(path: "/readyPlayers/\(playerID)", operation: .set(true)))
}
for playerID in removed {
    patches.append(StatePatch(path: "/readyPlayers/\(playerID)", operation: .delete))
}
```

### 優點
- **大幅減少計算量**：只處理變更的部分
- **頻寬節省**：只傳輸變更的資料
- **與 dirty tracking 配合**：可以做到非常細粒度的控制

### 挑戰
- 需要實作容器類型的特殊處理
- 變更偵測的實作複雜度較高

---

## 4. 快取策略優化

### 目標
優化快取策略，減少不必要的快取更新。

### 設計方向

#### 4.1 增量快取更新

當使用 dirty tracking 時，只更新 cache 中 dirty 字段的部分：

```swift
// 優化前：每次更新整個 snapshot
lastBroadcastSnapshot = currentBroadcast

// 優化後：只更新 dirty 字段
if useDirtyTracking {
    for (key, value) in currentBroadcast.values where dirtyFields.contains(key) {
        lastBroadcastSnapshot.values[key] = value
    }
} else {
    lastBroadcastSnapshot = currentBroadcast
}
```

### 優點
- **減少記憶體分配**：不需要重新建立整個 snapshot
- **減少序列化開銷**：只序列化 dirty 字段

### 挑戰
- 需要仔細處理 nested 結構的更新
- 需要確保 cache 的一致性

---

## 5. 效能監控與調優

### 目標
提供效能監控工具，幫助開發者識別效能瓶頸。

### 設計方向

#### 5.1 效能指標收集

```swift
struct SyncEngineMetrics {
    var snapshotGenerationTime: TimeInterval
    var diffComputationTime: TimeInterval
    var serializationTime: TimeInterval
    var dirtyFieldsCount: Int
    var totalFieldsCount: Int
}
```

#### 5.2 效能分析工具

提供工具來分析效能瓶頸：
- 哪些欄位最常被標記為 dirty
- 哪些欄位的比較最耗時
- 哪些欄位的序列化最耗時

---

## 總結

這些優化策略旨在提升 SwiftStateTree 的效能，特別是針對大型狀態樹和高頻更新場景。通過自動化的 dirty tracking、細粒度追蹤和容器優化，可以大幅減少不必要的計算和頻寬開銷。

**重要提醒**：
- ✅ **必須使用系統提供的 CRUD 函數**：通過 `@Sync` setter 或 `ReactiveDictionary`/`ReactiveSet` 的方法來修改集合類型
- ✅ **初始化所有字段**：在第一次 sync 時明確初始化所有字典/數組字段（即使是空的），確保它們都在 cache 中
- ✅ **理解優化版的行為**：優化版可能生成不同層級的 patch，但都能正確同步狀態

---

## 執行時間優化

### 固定頻率調度

當執行時間 > interval 時，使用固定頻率調度可以避免頻率持續下降：

**問題場景**：
- 如果執行時間 = 20ms，interval = 16ms
- 原來的實作：實際間隔 = 36ms（20ms 執行 + 16ms 休息），頻率下降

**解決方案**：
- 固定頻率：從預定時間開始計算，而不是從現在
- 如果執行時間太長，跳過一些更新以保持頻率

**優勢**：
- 保持固定頻率，即使執行時間變長
- 不會因為執行時間變長而導致頻率持續下降
