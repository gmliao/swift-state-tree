[English](sync.md) | [中文版](sync.zh-TW.md)

# Sync 與同步策略

StateTree 同步依賴 `@Sync` + `SyncPolicy`，由 SyncEngine 產生 snapshot/diff。

## 設計說明

- 讓同步規則可宣告在型別上（`@Sync`），與 handler 邏輯解耦
- 支援 per-player 過濾，避免多餘資料外洩或浪費頻寬
- 以 snapshot/diff 合併模式降低同步成本

## SyncPolicy 類型

- `.serverOnly`：不同步給 client
- `.broadcast`：所有 client 相同資料
- `.perPlayerSlice()`：Dictionary 專用 convenience method，自動切割 `[PlayerID: Element]` 只同步該玩家的 slice（**使用頻率高**，不需要提供 filter）
- `.perPlayer((Value, PlayerID) -> Value?)`：需要手動提供 filter function，依玩家過濾（適用於任何類型，**使用頻率低**，用於需要自定義過濾邏輯的場景）
- `.masked((Value) -> Value)`：同型別遮罩（所有玩家看到相同遮罩值）
- `.custom((PlayerID, Value) -> Value?)`：完全自定義

### Filter 看得到什麼

`.perPlayer` filter 只會收到該欄位的值與玩家 ID，無法讀取狀態的其他欄位、land 或 service。Filter 也必須是這兩個參數的純函式，因為每次同步都會對每位玩家執行。當可見性取決於其他狀態（位置、隊伍、戰爭迷霧）時，請在該狀態改變的地方計算（通常是 tick 或 handler），並存放在資料旁邊，讓 filter 讀得到：

```swift
@StateNodeBuilder
struct Entity: StateNodeProtocol {
    @Sync(.broadcast) var position: Position2 = Position2(x: 0, y: 0)
    @Sync(.serverOnly) var visibleTo: [PlayerID] = []  // 由 tick 設定，不會送出
}

@StateNodeBuilder
struct ArenaState: StateNodeProtocol {
    // 每位玩家只會收到 visibleTo 包含自己的 entity。
    @Sync(.perPlayer({ (entities: [String: Entity], playerID: PlayerID) in
        entities.filter { $0.value.visibleTo.contains(playerID) }
    }))
    var entities: [String: Entity] = [:]
}
```

Filter 從收到的值讀取 `visibleTo`，而 `visibleTo` 本身留在 server 上。GameDemo 的 visibility-test land（`VisibilityTestLand.swift`）是完整範例。

### 巢狀 State Node

State node 不論位於何處，都套用其欄位自身的 policy：作為欄位、在 optional 中、在 array 中，或作為 `[String: X]`、`[PlayerID: X]` map 的值，任何深度皆然。子欄位看到的是父欄位 filter 過後的結果，再套用自己的 policy：

| 父 \ 子 | `.broadcast` | `.serverOnly` | `.masked` | `.perPlayer` / `.perPlayerSlice()` / `.custom` |
|---|---|---|---|---|
| `.broadcast` | 所有玩家 | 不會送出 | 所有玩家，套用 mask | **拒絕** |
| `.perPlayer` / `.perPlayerSlice()` / `.custom` | 看得到父欄位的玩家 | 不會送出 | 看得到父欄位的玩家，套用 mask | 兩層 filter 都套用 |
| `.masked`（node 型別的欄位） | 先執行 mask，再套用子欄位的 policy | | | |
| `.serverOnly` | 以下都不會送出 | | | |

**依玩家而變的欄位不能有 `.broadcast` 祖先**（#179），不論中間隔著哪種容器。broadcast 欄位只在沒有玩家的情況下編碼一次，送給所有人，因此其下的 per-player 欄位在 diff 中送不到該玩家。`LandTypeRegistry.init`（因此涵蓋所有提供該 Land 的 host）、`NIOLandHost.register`、`SchemaExtractor.extract` 與 `SchemaGenCLI.generateSchema` 會以 `SyncPolicyNestingError` 拒絕這種 state，錯誤中列出每個欄位與其 broadcast 祖先；`SyncPolicyNesting.validate(_:)` 執行同樣的檢查。一般的 struct 或 class（不是 state node）會透過預設實例檢查其內容，因為 encoder 會像對待子節點一樣走訪其 stored property；檢查看不到的部分（例如空陣列的元素）會在 broadcast 編碼遇到時被拒絕（`SyncError.unsupportedValue`）。macro 無法辨識的 policy（不是寫成 `.name` 或 `.name(...)`）一律 fail closed，且每個 `@Sync` property 都必須明確標註型別。per-player 資料請改放在頂層的 per-player 欄位：

```swift
@StateNodeBuilder
struct Unit: StateNodeProtocol {
    @Sync(.broadcast) var hp: Int = 100        // 所有玩家
    @Sync(.serverOnly) var aiState: Int = 0    // 不會送出
    @Sync(.masked({ $0 / 10 * 10 })) var shield: Int = 0 // 所有玩家，取整
}

@StateNodeBuilder
struct GameState: StateNodeProtocol {
    @Sync(.broadcast) var units: [PlayerID: Unit] = [:]
    // unit 的 per-player 資料放在頂層：每個玩家只收到自己的項目。
    @Sync(.perPlayerSlice()) var hints: [PlayerID: [PlayerID: Int]] = [:]
}
```

2026-11-05 之前（#178），位於 `[String: X]` 或 `[PlayerID: X]` map 中的 `@SnapshotConvertible` node 會連同所有欄位一起送出，包含 server-only 欄位。在那之前錄製的 recording 雜湊會不同；見 [Re-evaluation](reevaluation.zh-TW.md)。

## Snapshot 與 Diff

- snapshot：完整狀態（含 per-player 過濾）
- diff：只傳變更（path-based patches）

SyncEngine 會維護：

- broadcast 快取：所有玩家共用
- per-player 快取：每個玩家獨立

### 同步值型別的規則

typed sync diff（`USE_SYNC_TABLES`，實驗性功能，預設關閉）會把每個 broadcast 欄位上次送出的值以原生 Swift 值保存，並在產生任何 patch 之前先用 `==` 比較目前的值與它。它依賴三條規則。遵守這些規則的型別在現行路徑上行為相同。

- **`==` 不能蓋掉變更。** 若 `a == b`，兩個值必須轉換成相同的 snapshot。自訂的 `==` 若忽略某個會同步的屬性就違反這條：該變更永遠不會送出。Debug build 偵測到時會回報。
- **轉換只取決於值本身。** `toSnapshotValue()` 對相同的值每次都必須回傳相同的 snapshot，因此不能讀取時鐘、計數器或其他外部狀態。
- **同步值必須是值語意。** 同步值不能與 live state 共用可變狀態。欄位型別是 class，或是含有 class 的集合或 state node 時，會被偵測到並沿用現行的 diff 方式。藏在 struct、enum 或 existential 裡的 class 無法偵測：若它被就地修改，不會送出 patch。

## First Sync

`StateUpdate.firstSync` 會在玩家 cache 首次建立後送出一次，
避免 join snapshot 與第一個 diff 的競態。

## Dirty Tracking

`@Sync` 會在寫入時標記 dirty，用於降低 diff 成本。
TransportAdapter 可在執行期切換 dirty tracking：

- 開啟：只序列化 dirty 欄位
- 關閉：每次同步都全量 snapshot

## 手動同步

在 handler 內可透過 `ctx.requestSyncNow()`（或 `ctx.requestSyncBroadcastOnly()`）請求 deterministic 的同步。
