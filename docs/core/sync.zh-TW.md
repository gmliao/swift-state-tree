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

Policy 屬於宣告，而不是每個值。`@StateNodeBuilder` 會把 `@Sync` 的參數為該 node 型別產生一次，所有 instance 都經由它過濾：
- 非泛型、且沒有巢狀在泛型型別、extension 或函式裡的 node 型別：用來過濾的 policy 只在第一次使用時求值一次，所有 instance 共用。
- 其他 node 型別：每次使用時都會求值。
- 兩種情況下，只要 init 經由 attribute 初始化該欄位（宣告時給的初始值，或在 init 裡寫 `self.x = …`），attribute 的參數也都會在那次初始化時求值一次，那個值隨即丟棄。所以像 `.perPlayerSlice()` 這樣的 factory 仍會在每次這樣的初始化時執行。欄位宣告時若沒有初始值，在 init 裡手動建立 wrapper 則不會求值。

Policy 以 attribute 裡寫的為準。在 init 裡手動建立 wrapper（`_x = Sync(wrappedValue: v, .serverOnly)`）不會改變它：傳入的 policy 會被忽略。

因此 policy 運算式和它的 filter 一樣必須是純的：要能在任何環境下呼叫（同步可能在建立狀態以外的 executor 上執行），也不能依賴 land 啟動後會改變的任何東西。

### 巢狀 State Node

State node 不論位於何處，都套用其欄位自身的 policy：作為欄位、在 optional 中、在 array 中，或作為 `[String: X]`、`[PlayerID: X]` map 的值，任何深度皆然。子欄位看到的是父欄位 filter 過後的結果，再套用自己的 policy：

| 父 \ 子 | `.broadcast` | `.serverOnly` | `.masked` | `.perPlayer` / `.perPlayerSlice()` / `.custom` |
|---|---|---|---|---|
| `.broadcast` | 所有玩家 | 不會送出 | 所有玩家，套用 mask | **拒絕** |
| `.perPlayer` / `.perPlayerSlice()` / `.custom` | 看得到父欄位的玩家 | 不會送出 | 看得到父欄位的玩家，套用 mask | 兩層 filter 都套用 |
| `.masked`（node 型別的欄位） | 先執行 mask，再套用子欄位的 policy | | | |
| `.serverOnly` | 以下都不會送出 | | | |

**依玩家而變的欄位不能有 `.broadcast` 祖先**（#179），不論中間隔著哪種容器。broadcast 欄位只在沒有玩家的情況下編碼一次，送給所有人，因此其下的 per-player 欄位在 diff 中送不到該玩家。`LandTypeRegistry.init`（因此涵蓋所有提供該 Land 的 host）、`NIOLandHost.register`、`SchemaExtractor.extract` 與 `SchemaGenCLI.generateSchema` 會以 `LandRegistrationError` 拒絕這種 state：其 `sync` 含有 `.policyNesting` 問題，也就是列出每個欄位與其 broadcast 祖先的 `SyncPolicyNestingError`（見[註冊時拒絕的型別](#註冊時拒絕的型別)）；`SyncPolicyNesting.validate(_:)` 執行同樣的檢查。一般的 struct（不是 state node）會透過預設實例檢查其內容，因為 encoder 會像對待子節點一樣走訪其 stored property；檢查看不到的部分（例如空陣列的元素）會在 broadcast 編碼遇到時被拒絕（`SyncError.unsupportedValue`）。macro 無法辨識的 policy（不是寫成 `.name` 或 `.name(...)`）一律 fail closed，且每個 `@Sync` property 都必須明確標註型別。per-player 資料請改放在頂層的 per-player 欄位：

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

### 同步狀態只能由 value type 組成

每個 `@Sync` 欄位在任何深度都只能放 value type（struct、enum、由它們組成的集合、state node）（#464）。Diff 比較的是值；debug build 也會拿 handler 執行前的副本檢查拋出錯誤的 handler 是否寫入過（見 [Runtime](runtime.zh-TW.md#input-與-turn)）。透過共用物件的寫入兩者都看不到，因此同步狀態中的 class 會被拒絕：
- **註冊時。** `LandTypeRegistry.init`（因此涵蓋所有提供該 Land 的 host）、`NIOLandHost.register`、`SchemaExtractor.extract` 與 `SchemaGenCLI.generateSchema` 會拋出 `LandRegistrationError`，其 `sync` 含有 `.valueSemantics` 問題，也就是列出每個欄位與 class 的 `SyncValueSemanticsError`，例如 `GameState.inventory: Inventory is a class; synced state must be value types`。檢查會走訪每個同步欄位的型別（包含 `.serverOnly` 欄位），穿過 optional、array、set、dictionary 的 key 與 value，以及巢狀 state node，並透過預設實例檢查一般 struct、tuple、enum payload 與 existential 欄位（`any P`）的內容。
- **轉換狀態時。** 檢查看不到的 class（之後才存入 existential 欄位的、位於預設實例沒有採用的 enum case 裡的、或加進註冊時還是空的集合裡的）會讓轉換拋出 `SyncError.unsupportedValue`。Dictionary 的 key 是例外：key 是透過它的 description 轉換的，因此放在 value type key 內部的 class（例如含有 class 屬性的 `CustomStringConvertible` struct）只有在註冊時、且預設實例的第一個 key 含有 class 時才會被拒絕（檢查只取 dictionary 的第一個項目）。每次同步都會轉換，因此該 Land 的同步會失敗（`.serverOnly` 欄位只在錄製或計算狀態雜湊時，以及 debug build 檢查拋出錯誤的 handler 是否寫入時才會轉換，因此失敗的是這些步驟）；若 class 位於事件 payload 中，sync-output verifier 無法將該事件正規化，會把 events 範圍回報為無法驗證。

請把型別改成 struct 或 enum。Land 需要但不同步的參照（例如快取或 service handle）放在 `@Internal` 欄位，這類欄位不受檢查。`SnapshotValueConvertible` 型別由它自己的 `toSnapshotValue()` 轉換，但其儲存內容仍會被檢查：遵循此 protocol 的 class 會被拒絕，預設實例含有 class 的遵循 struct 也會被拒絕。

**破壞性變更（2026-11-10）。** #464 之前，同步狀態中的 class 會依其 stored property 編碼，只有參照回自己的物件圖會被拒絕。現在狀態含有 class 的 Land 會註冊失敗。

### 註冊時拒絕的型別

所有只由 state 型別就能決定的註冊檢查，都在同一個錯誤中回報（#535）。`LandDefinition.validateForRegistration(context:)` 執行這些檢查，`NIOLandHost.register`、`LandTypeRegistry.init`、`SchemaExtractor.extract`、`SchemaGenCLI` 與 `ReevaluationEngine.run` 都會呼叫它。它們拋出 `LandRegistrationError`，其 `sync` 是 `SyncRegistrationError`，每一列對應一種問題：

| 問題 | 意義 |
|---|---|
| `.valueSemantics(SyncValueSemanticsError)` | 同步欄位含有 class（見上文） |
| `.policyNesting(SyncPolicyNestingError)` | broadcast 欄位下有依玩家而變的欄位（見上文） |
| `.unsupportedKey(path:keyType:)` | 同步無法轉成字串的 dictionary key 型別：不是 `String`、`PlayerID` 或 `CustomStringConvertible` |
| `.existentialField(path:typeName:)` | 能容納任何型別值的同步型別：`Any`、`AnyObject`、`AnyHashable` 或 `AnyCodable`，出現在集合的元素、key 或 value，或 optional 包住的型別 |

class 檢查涵蓋 `.serverOnly` 欄位，key 與 existential 檢查只涵蓋會送出的欄位；`@SnapshotConvertible` 型別透過其宣告的 stored property 檢查（由 macro 列出，因此有標註型別的 property 即使位於空集合中也會檢查；沒有標註型別的 property 只能透過預設實例的值檢查），其他一般 struct 則同樣透過預設實例檢查其內容。手寫 `toSnapshotValue()` 的型別自行轉換其儲存內容，不會被檢查；只遵循 `FullSnapshotValueConvertible` 不算，因為同步會忽略它。結果依 state 型別快取，因此 **state 型別的預設 `init()` 必須是確定性的**：每次呼叫都產生相同的值，不讀時鐘、亂數來源或全域狀態。

**編譯期。** `@StateNodeBuilder`（針對 `@Sync` 欄位）與 `@SnapshotConvertible`（針對每個 stored property）會拒絕宣告型別中寫出 `any P`、`Any`、`AnyObject` 或 protocol 組合（`P & Q`）的欄位，不論位於哪一層（`[String: Any]`、`(any P)?`、`Box<any P>`），`AnyHashable` 與 `AnyCodable` 則依名稱拒絕。這類欄位的內容無法檢查，同步也可能無法轉換。`@Internal` 欄位不同步，可以放任何東西。

**抓不到的情況。** 未加 `any` 的 protocol 名稱（`var p: P`）、指向 existential 的 typealias，以及手寫 conformance 的型別，macro 都看不到。一般 struct（沒有 `@SnapshotConvertible`）在註冊時只能透過預設實例的值檢查，因此其宣告為 `Any` 或 `any P` 的 property，會被當成當時所存值的型別檢查（`var x: Any = 0` 會以 `Int` 通過）；Swift 的 reflection 拿不到宣告的型別。手寫 `toSnapshotValue()` 的儲存內容不會被檢查。這些情況由同步作為最後防線：第一個無法轉換的值會結束 land（[失敗處理](failure-handling.zh-TW.md)）。不經 host 或 registry 直接建立的 keeper 會在初始化時執行同一個檢查：未通過的 state 型別會讓初始化失敗，與 OnInitialize resolver 逾時相同。

**破壞性變更（2026-11-17）。** #535 之前，註冊時分別拋出 `SyncValueSemanticsError` 與 `SyncPolicyNestingError`，而不支援的 key 型別或 existential 欄位要到同步時才發現。遷移方式：
- `catch is SyncValueSemanticsError` 不再匹配。請 catch `LandRegistrationError` 並讀取其 `sync?.problems`；舊的錯誤是 `.valueSemantics` 或 `.policyNesting` 的 associated value。
- existential 欄位改用具體型別，或為每種可能的值各設一個 case 的 enum。`AnyCodable` 或 `AnyHashable` 欄位同樣處理；不支援的 key 型別改用 `String`、`PlayerID` 或 `CustomStringConvertible` 的 key。

## Snapshot 與 Diff

- snapshot：完整狀態（含 per-player 過濾）
- diff：只傳變更（path-based patches）

SyncEngine 會維護：

- broadcast 快取：所有玩家共用
- per-player 快取：每個玩家獨立

### 同步值型別的規則

typed sync diff（`USE_SYNC_TABLES`，預設路徑；設為 `false` 可退回 snapshot diff，此 fallback 之後會移除；但 row addressing 實際生效之處會保持 tables 開啟，見 transport README）會把每個 broadcast 欄位上次送出的值以原生 Swift 值保存，並在產生任何 patch 之前先用 `==` 比較目前的值與它。它依賴以下規則。遵守這些規則的型別在現行路徑上行為相同。`TYPED_LEAF_VALUES`（預設開啟）開啟時，內建 leaf 型別的欄位變更會改以型別專屬的轉換取代通用轉換；patch 與位元組相同，使用者自訂的型別仍走通用轉換。

- **一般的值要是 `Equatable` 才會用型別化的比較。** 同步的 struct、enum 或集合若不是 `Equatable`，會沿用現行的轉換與 diff 方式。兩種方式送出的 frame 位元組相同，只有成本不同。
- **`==` 不能蓋掉變更。** 若 `a == b`，兩個值必須轉換成相同的 snapshot。自訂的 `==` 若忽略某個會同步的屬性就違反這條：該變更永遠不會送出。Debug build 偵測到時會回報。
- **轉換只取決於值本身。** `toSnapshotValue()` 對相同的值每次都必須回傳相同的 snapshot，因此不能讀取時鐘、計數器或其他外部狀態。
- **Map 的 key 與 player ID 以 NFC 送出。** 轉換 state 時，dictionary 的 key 會寫成 Unicode 正規化形式 C；`PlayerID` 從建立起就以 NFC 保存 raw value。因此不論 server 拿到哪一種拼法，同一個 key 在 wire 上只有一種拼法（Swift 的 `String ==` 本來就把它們視為同一個 key）。ASCII 文字不變。在手寫的 `toSnapshotValue()` 裡自行組出 object 的型別必須自己寫出 NFC 的 key：它的 key 會照寫出的樣子送出。
- **同步值必須是值語意。** 同步值不能與 live state 共用可變狀態。欄位型別是 class，或是含有 class 的 optional、array、dictionary、set 或 state node 時，會被偵測到並沿用現行的 diff 方式。藏在 struct、enum 或 existential 裡的 class 無法偵測：若它被就地修改，不會送出 patch。
- **編譯與 log 會告訴你哪些欄位沒有受益。** 同步欄位的型別不是 `Equatable` 時，`@StateNodeBuilder` 會在編譯期對該欄位發出警告（警告會指出欄位名稱與型別；除了讓型別成為 `Equatable` 之外，沒有其他方式可以關閉它）。欄位型別若用到所在 node 的泛型參數，編譯期不會檢查，因為它是否為 `Equatable` 取決於該參數實際綁定的型別；這種欄位由 log 涵蓋。其他原因編譯器看不到，因此某個 state 型別的第一個 land 以 typed diff 啟動時，會記錄一則 warning，列出所有沿用舊 diff 方式的欄位與各自的原因。

## First Sync

`StateUpdate.firstSync` 會在玩家 cache 首次建立後送出一次，
避免 join snapshot 與第一個 diff 的競態。

## Dirty Tracking

`@Sync` 會在寫入時標記 dirty，用於降低 diff 成本。
dirty tracking 每個 adapter 固定：由 `ENABLE_DIRTY_TRACKING`（預設開啟）設定，執行期可用 `setDirtyTrackingEnabled(_:)` 變更。adapter 不會自行切換。

- 開啟：只序列化 dirty 欄位
- 關閉：每次同步都全量 snapshot

## 手動同步

在 handler 內可透過 `ctx.requestSyncNow()`（或 `ctx.requestSyncBroadcastOnly()`）請求 deterministic 的同步。
