# 效能優化計劃

> 本文檔記錄 SwiftStateTree 的後續效能優化計劃和設計方向

## 概述

目前 SwiftStateTree 已經實現了基本的同步機制和 diff 計算，**並支援遞迴過濾功能**（巢狀 StateNode 可以獨立套用 @Sync 政策）。

**重要說明**：遞迴過濾已經解決了以下問題：
- ✅ **細粒度過濾**：不需要 ReactiveDictionary，可以用 StateNode 來細分
- ✅ **Per-Player 細分**：不需要 Per-Player State View 架構，遞迴過濾已經可以做到

為了進一步提升效能，特別是針對大型狀態樹和高頻更新場景，我們計劃實施以下優化策略。

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
