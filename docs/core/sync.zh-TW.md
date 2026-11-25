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

每個 state 欄位在任何深度都只能放純資料：struct、enum、由它們組成的集合與 state node（#464）。Diff 拿值與先前取得的狀態副本比較；透過共用物件的寫入也會改到那份副本，diff 看不到。

**編譯期。** `StateNodeProtocol` 繼承 `PlainData`（[什麼算純資料](../turns/README.zh-TW.md#什麼算純資料)）。`@StateNodeBuilder` 會寫出這個 conformance 的檢查。每個 `@Sync` 與 `@Internal` 欄位有兩行，一行檢查 wrapper 的儲存內容，一行檢查它的值，只有讀到的東西是 `PlainData` 時才能編譯。`#if` 裡的 `@Internal` 欄位在同樣的條件下檢查。因此在任何欄位（同步、`.serverOnly` 或 `@Internal`），編譯器都會拒絕：
- class、closure、tuple、`Any` 或 `AnyObject`，不論位於哪一層，藏在 typealias 後面也一樣；
- 欄位本身的 existential `any P`。巢狀的 `@PlainData` 型別可以存放 `any P`，只要 `P` 繼承 `PlainData`，因為這時它的值也是純資料；
- `Date`、`UUID`、`URL` 與 `Decimal`；錯誤訊息會指出改存什麼；
- 不是 `PlainData` 的自訂 struct 或 enum。請加上 `@PlainData`，或 `@SnapshotConvertible`（它會寫出同樣的 conformance）。`SwiftStateTree` 會 re-export `SwiftStateTurns` 的 `@PlainData`。

```swift
@PlainData
struct Card: Codable, Equatable, Sendable {
    var rank: Int
}

@StateNodeBuilder
struct TableState: StateNodeProtocol {
    @Sync(.broadcast) var cards: [String: Card] = [:]
    @Internal var turnCount: Int = 0
}
```

同一條規則也影響幾種宣告：
- generic node 的型別參數必須是 `PlainData`：`struct Box<T: PlainData & Sendable>: StateNodeProtocol`。
- 不用 `@StateNodeBuilder`、手寫 conformance 的 state node 要加上 `@PlainData`。這只適用於 stored property 都沒有 property wrapper 的 node，因為 `@PlainData` 拒絕所有 wrapper。有 `@Sync` 或 `@Internal` 欄位的 node 請用 `@StateNodeBuilder`。
- state 欄位上 `@Sync` 與 `@Internal` 以外的 property wrapper 會被拒絕：檢查讀不到其他 wrapper 的儲存內容。自己定義、名為 `Sync` 或 `Internal` 的 wrapper 會被讀穿，但它的儲存內容會被檢查，所以只有它是純資料時才能編譯。加上 module 名稱的寫法，只有在 module 匯出了 library 的 wrapper 時才會被讀穿，例如 `@SwiftStateTree.Sync`。
- `#if` 裡的 `@Sync` 欄位會被拒絕：同步只讀型別最上層的欄位，所以它永遠不會被同步。請宣告在 `#if` 之外，或標記為 `@Internal`。
- 有 observer（`willSet`、`didSet`）的 property 是 stored property，所以和其他欄位一樣需要標記。標記 `@Sync` 的會被拒絕：產生的 mutator 與 snapshot decode 直接寫入欄位的儲存內容，observer 只會在部分寫入時執行。標記 `@Internal` 的可以保留 observer。
- 成員中的 freestanding macro 展開（`#someMacro()`）會被拒絕，因為它加入的儲存內容不在檢查所讀的語法裡。`#warning` 與 `#error` 是編譯器指令，可以使用。
- state 型別與 `@SnapshotConvertible` 型別只能掛本專案的 macro（`@StateNodeBuilder`、`@SnapshotConvertible`、`@PlainData`、`@Payload`），以及不加入成員的內建 attribute（例如 `@available`）。其他 attached macro 會被拒絕，因為它可能加入檢查看不到的成員。
- `@StateNodeBuilder` 旁邊加 `@PlainData` 會被拒絕，因為這個 macro 已經寫出檢查。旁邊加 `@SnapshotConvertible` 沒有問題。
- `@SnapshotConvertible` 型別的每個 stored property 都要標註型別，與 `@PlainData` 相同。

Land 需要但不同步的參照（例如快取或 service handle）放在 land 的 services。

**註冊與轉換時。** 有兩種情況會通過編譯期檢查：
- **手寫的 witness。** 型別可以用它（`static func _plainDataCheck() {}`）符合 `PlainData`，這樣什麼都不檢查。本 repository 的 lint 會拒絕它，但在 repository 之外的專案可以編譯。
- **自己定義、與本專案 macro 同名的 macro。** macro 只看得到寫法，看不到宣告。因此在自己的 module 裡定義、名為 `SnapshotConvertible` 的 macro，不加 module 名稱掛在 `@StateNodeBuilder` 旁邊時，會被當成本專案的 macro，它加入的成員不會被檢查。

對這兩種情況，編譯器之後還留著兩道執行期檢查：
- **註冊時。** `LandTypeRegistry.init`（因此涵蓋所有提供該 Land 的 host）、`NIOLandHost.register`、`SchemaExtractor.extract` 與 `SchemaGenCLI.generateSchema` 會拋出 `LandRegistrationError`，其 `sync` 含有 `.valueSemantics` 問題，也就是列出每個欄位與 class 的 `SyncValueSemanticsError`，例如 `GameState.inventory: Inventory is a class; synced state must be value types`。檢查會走訪每個同步欄位的型別（包含 `.serverOnly` 欄位），穿過 optional、array、set、dictionary 的 key 與 value，以及巢狀 state node，並透過預設實例檢查一般 struct、tuple、enum payload 與 existential property（`any P`）的內容。
- **轉換狀態時。** 檢查看不到的 class（之後才存入 existential 欄位的、位於預設實例沒有採用的 enum case 裡的、或加進註冊時還是空的集合裡的）會讓轉換拋出 `SyncError.unsupportedValue`。Dictionary 的 key 是例外：key 是透過它的 description 轉換的，因此放在 value type key 內部的 class（例如含有 class 屬性的 `CustomStringConvertible` struct）只有在註冊時、且預設實例的第一個 key 含有 class 時才會被拒絕（檢查只取 dictionary 的第一個項目）。每次同步都會轉換，因此該 Land 的同步會失敗（`.serverOnly` 欄位只在錄製或計算狀態雜湊時才會轉換，因此失敗的是這些步驟）；若 class 位於事件 payload 中，sync-output verifier 無法將該事件正規化，會把 events 範圍回報為無法驗證。

DeterministicMath 的值型別（`IVec2`、`Position2` 等）都是 `PlainData`，所以任何 state 欄位都可以存放它們。`SnapshotValueConvertible` 型別由它自己的 `toSnapshotValue()` 轉換，但它的型別仍必須是 `PlainData`，註冊時也仍會拒絕遵循此 protocol 的 class。

**破壞性變更（2026-11-10）。** #464 之前，同步狀態中的 class 會依其 stored property 編碼，只有參照回自己的物件圖會被拒絕。現在狀態含有 class 的 Land 會註冊失敗。

**破壞性變更（2026-11-25）。** state 型別現在是 `PlainData`。以下寫法不再能編譯：沒有 `@PlainData` 或 `@SnapshotConvertible` 的巢狀 struct 或 enum、型別參數不是 `PlainData` 的 generic node、沒有 `@PlainData` 的手寫 node、tuple 欄位、`.serverOnly` 的 `Decimal`、藏在 typealias 後面的 existential，以及沒有標註型別的 `@SnapshotConvertible` property。`ReactiveDictionary` 與 `ReactiveSet` 已移除：請在 `@Sync` 欄位中使用 `Dictionary` 或 `Set`。整個欄位一起標記為 dirty：沒有逐 key 的 dirty tracking、沒有新增或移除元素的清單，也沒有變更 callback。

### 註冊時拒絕的型別

所有只由 state 型別就能決定的註冊檢查，都在同一個錯誤中回報（#535），只有型別名稱那一列例外：它只在其他各列都通過時才執行。`LandDefinition.validateForRegistration(context:)` 執行這些檢查，`NIOLandHost.register`、`LandTypeRegistry.init`、`SchemaExtractor.extract`、`SchemaGenCLI` 與 `ReevaluationEngine.run` 都會呼叫它。它們拋出 `LandRegistrationError`，其 `sync` 是 `SyncRegistrationError`，每一列對應一種問題：

| 問題 | 意義 |
|---|---|
| `.valueSemantics(SyncValueSemanticsError)` | 同步欄位含有 class，藏在手寫的 `PlainData` witness 後面（見上文） |
| `.policyNesting(SyncPolicyNestingError)` | broadcast 欄位下有依玩家而變的欄位（見上文） |
| `.unsupportedKey(path:keyType:)` | 同步無法轉成字串的 dictionary key 型別：不是 `String`、`PlayerID` 或 `CustomStringConvertible` |
| `.existentialField(path:typeName:)` | 能容納任何型別值的同步型別：`Any`、`AnyObject`、`AnyHashable` 或 `AnyCodable`，出現在集合的元素、key 或 value，或 optional 包住的型別，藏在手寫的 `PlainData` witness 後面 |
| `.decimalField(path:)` | 藏在手寫的 `PlainData` witness 後面的同步 `Decimal`，不論單獨出現，或位於 optional、集合或巢狀型別中（#597）；見下文 |
| `.typeNameCollision(SchemaTypeNameCollision)` | state 中兩個不同的型別同名，例如 `A.Item` 與 `B.Item`（#602）；只在上面各列都通過時才檢查；見下文 |

class 檢查涵蓋 `.serverOnly` 欄位，key 與 existential 檢查只涵蓋會送出的欄位；`@SnapshotConvertible` 型別透過其宣告的 stored property 檢查（由 macro 列出，因此 property 即使位於空集合中也會檢查），其他一般 struct 則同樣透過預設實例檢查其內容。手寫 `toSnapshotValue()` 的型別自行轉換其儲存內容，不會被檢查；只遵循 `FullSnapshotValueConvertible` 不算，因為同步會忽略它。結果依 state 型別快取，因此 **state 型別的預設 `init()` 必須是確定性的**：每次呼叫都產生相同的值，不讀時鐘、亂數來源或全域狀態。

**型別名稱。** schema 用型別的名稱來稱呼它描述的每個型別，不含外層的型別：`A.Item` 與 `B.Item` 都叫 `Item`。兩個不同的型別同名時會共用一份定義，產生的 client、path hash 與 atomic 值的位置編碼都會拿其中一個型別的欄位套用到兩者。在 state 中，註冊時就拒絕（`.typeNameCollision`）。在 schema 的其他地方，產生 schema 時拒絕：`SchemaExtractor.extract` 與 `SchemaGenCLI.generateSchema` 拋出 `SchemaTypeNameCollisionError`，列出每個共用的名稱與其型別的完整名稱（#602）。會被 replay 的 land 計算紀錄的 schema fingerprint 時也會拒絕，它還會走訪 land 的 server input：與 state 型別同名的 server input 在那裡被拒絕，註冊時以 `LandRegistrationError.typeNameCollisions` 回報。例如 client event `A.HitEvent` 與 server event `B.HitEvent`、同一份 schema 的兩個 land 各用不同的 `Item`，以及名為 `StateDiff` 的型別（schema 的 diff 佔位定義用的名稱）。同名的型別只保留一個名稱，其餘改名；`StateDiff` 是保留名稱，用到它的型別都要改名。

**Decimal。** `Decimal` 沒有 wire 形式（#597）。它的 `Codable` 形式是平台內部的欄位，同步無法轉換它。JavaScript client 會把 JSON 數字讀成 double 而失去位數。JSON 編碼會把 Decimal NaN 寫成裸 `NaN`，那不是合法的 JSON。金額請存成最小單位（分）的整數，或 `String`。`Decimal` 在三個地方被拒絕，依序如下：

- **編譯期。** 在 state 中是每個欄位：`Decimal` 不是 `PlainData`，所以不論怎麼寫（包括 typealias），編譯器都會拒絕，錯誤訊息會指出改存什麼。`@Payload` 在宣告的型別寫出 `Decimal` 或 `Foundation.Decimal` 時檢查每個欄位，不論位於哪一層，例如 `[String: Decimal]`。
- **註冊時，** typealias 讓語法看不到、但欄位清單看得到時，以及藏在手寫的 `PlainData` witness 後面時。同步欄位回報為 `.decimalField`。event、action、其 response 或 server input 的欄位在 `LandRegistrationError.decimalFields` 中回報，每個欄位一條路徑，例如 `server event PriceEvent.amount`。
- **第一次送出時，** 前兩者都看不到的：未註冊就送出的 event、執行時放進 `Decimal` 的 `AnyCodable`，以及一般 `Codable` 型別（不列出欄位）裡的 `Decimal`。JSON 編碼與 MessagePack encoder 都拒絕它，land 結束（`.eventEncode` 或 `.responseEncode`）。限制：在 JSON 編碼中，這個拒絕是編碼前另外走的一遍，所以手寫的 `encode(to:)` 若攔下這個錯誤、改寫成別的形式，就會通過檢查，之後實際編碼寫出的是那個替代形式。

任何 state 欄位都不能放 `Decimal`，`.serverOnly` 與 `@Internal` 也一樣。resolver output 可以，因為它不會上 wire；replay 時以錄製檔自己的 codec 讀回（[Replay 中的 resolver output](reevaluation.zh-TW.md#replay-中的-resolver-output)）。

**編譯期。** `@StateNodeBuilder`（針對 `@Sync` 欄位）與 `@SnapshotConvertible`（針對每個 stored property）也會以自己的訊息指出宣告型別中寫出 `any P`、`Any`、`AnyObject` 或 protocol 組合（`P & Q`）的欄位，不論位於哪一層（`[String: Any]`、`(any P)?`、`Box<any P>`），`AnyHashable` 與 `AnyCodable` 則依名稱指出（#535）。其餘的由 `PlainData` 檢查拒絕，包括未加 `any` 的 protocol 名稱與 typealias。

**抓不到的情況。** 手寫的 `PlainData` witness 什麼都不檢查。藏在它後面的一般 struct 在註冊時只能透過預設實例的值檢查，因此其宣告為 `Any` 或 `any P` 的 property，會被當成當時所存值的型別檢查（`var x: Any = 0` 會以 `Int` 通過）；Swift 的 reflection 拿不到宣告的型別。手寫 `toSnapshotValue()` 的儲存內容不會被檢查。這些情況由同步作為最後防線：第一個無法轉換的值會結束 land（[失敗處理](failure-handling.zh-TW.md)）。不經 host 或 registry 直接建立的 keeper 會在初始化時執行同一個檢查：未通過的 state 型別會讓初始化失敗，與 OnInitialize resolver 逾時相同。

**破壞性變更（2026-11-17）。** #535 之前，註冊時分別拋出 `SyncValueSemanticsError` 與 `SyncPolicyNestingError`，而不支援的 key 型別或 existential 欄位要到同步時才發現。遷移方式：
- `catch is SyncValueSemanticsError` 不再匹配。請 catch `LandRegistrationError` 並讀取其 `sync?.problems`；舊的錯誤是 `.valueSemantics` 或 `.policyNesting` 的 associated value。
- existential 欄位改用具體型別，或為每種可能的值各設一個 case 的 enum。`AnyCodable` 或 `AnyHashable` 欄位同樣處理；不支援的 key 型別改用 `String`、`PlayerID` 或 `CustomStringConvertible` 的 key。

## Snapshot 與 Diff

- snapshot：完整狀態（含 per-player 過濾）
- diff：只傳變更（path-based patches）

SyncEngine 會維護：

- broadcast 快取：所有玩家共用
- per-player 快取：每個玩家獨立

### Patch 涵蓋的範圍

一個 patch 會取代某個 path 上的值。diff 往下走多深才寫出 patch，取決於值的形狀：

- **state node、一般 struct 或字典會逐欄位或逐 key diff。** 每個變動的欄位或項目各自有一個 patch，位於自己的 path。新增的項目是該 key 上的 set；移除的項目是 delete。
- **array 或 `Set` 是單一值。** 它有任何變動（某個元素改變、新增、移除或移動），都會在它的 path 上重送整個集合。`Set` 會以固定順序（依每個元素編碼後的形式排序）的 array 送出。
- **atomic 值是單一值**（見 [Atomic 值](../transport/README.zh-TW.md#atomic-值)），純量也是：數字、字串或 `Bool`。

無論執行的是哪一種 diff 都是如此：typed sync diff（下一節說明）寫出的 patch 與 snapshot diff 相同。

舉例來說，一個有 100 名玩家的 land，每名玩家有一個帶 `score` 欄位的 `PlayerScore` struct，現在改了一名玩家的分數。如果 `scores` 是 `[PlayerScore]` array，patch 會帶上全部 100 個項目。如果 `scores` 是 `[PlayerID: PlayerScore]` 字典，它只帶變動的那個欄位，位於 `/scores/<player ID>/score`。

**建議。** 經常變動的大型集合，請放在以穩定 ID（`String`、`PlayerID` 或其他支援的 key 型別）為 key 的字典中，不要放在 array 裡。這樣每次變動只花一個項目中變動部分的成本。字典沒有順序。如果順序重要，就把順序存在值裡（`rank` 或 `order` 欄位），或另外保留一個小的 ID array，它只在順序改變時才整個重送。array 適合小型集合，或很少變動、或一次全部改變的集合。

### 同步值型別的規則

typed sync diff（`USE_SYNC_TABLES`，預設路徑；設為 `false` 可退回 snapshot diff，此 fallback 之後會移除；但 row addressing 實際生效之處會保持 tables 開啟，見 transport README）會把每個 broadcast 欄位上次送出的值以原生 Swift 值保存，並在產生任何 patch 之前先用 `==` 比較目前的值與它。它依賴以下規則。遵守這些規則的型別在現行路徑上行為相同。`TYPED_LEAF_VALUES`（預設開啟）開啟時，內建 leaf 型別的欄位變更會改以型別專屬的轉換取代通用轉換；patch 與位元組相同，使用者自訂的型別仍走通用轉換。

- **一般的值要是 `Equatable` 才會用型別化的比較。** 同步的 struct、enum 或集合若不是 `Equatable`，會沿用現行的轉換與 diff 方式。兩種方式送出的 frame 位元組相同，只有成本不同。
- **`==` 不能蓋掉變更。** 若 `a == b`，兩個值必須轉換成相同的 snapshot。自訂的 `==` 若忽略某個會同步的屬性就違反這條：該變更永遠不會送出。Debug build 偵測到時會回報。
- **轉換只取決於值本身。** `toSnapshotValue()` 對相同的值每次都必須回傳相同的 snapshot，因此不能讀取時鐘、計數器或其他外部狀態。
- **Map 的 key 與 player ID 以 NFC 送出。** 轉換 state 時，dictionary 的 key 會寫成 Unicode 正規化形式 C；`PlayerID` 從建立起就以 NFC 保存 raw value。因此不論 server 拿到哪一種拼法，同一個 key 在 wire 上只有一種拼法（Swift 的 `String ==` 本來就把它們視為同一個 key）。ASCII 文字不變。在手寫的 `toSnapshotValue()` 裡自行組出 object 的型別必須自己寫出 NFC 的 key：它的 key 會照寫出的樣子送出。
- **同步值必須是值語意。** 同步值不能與 live state 共用可變狀態。編譯器會拒絕 state 中的 class；只有手寫的 `PlainData` witness 能把 class 帶進來。欄位型別是這種 class，或是含有它的 optional、array、dictionary、set 或 state node 時，會被偵測到並沿用現行的 diff 方式。藏在這種 witness 後面的 struct、enum 或 existential 裡的 class 無法偵測：若它被就地修改，不會送出 patch。
- **編譯與 log 會告訴你哪些欄位沒有受益。** 同步欄位的型別不是 `Equatable` 時，`@StateNodeBuilder` 會在編譯期對該欄位發出警告（警告會指出欄位名稱與型別；除了讓型別成為 `Equatable` 之外，沒有其他方式可以關閉它）。欄位型別若用到所在 node 的泛型參數，編譯期不會檢查，因為它是否為 `Equatable` 取決於該參數實際綁定的型別；這種欄位由 log 涵蓋。其他原因編譯器看不到，因此某個 state 型別的第一個 land 以 typed diff 啟動時，會記錄一則 warning，列出所有沿用舊 diff 方式的欄位與各自的原因。

## First Sync

`StateUpdate.firstSync` 會在玩家 cache 首次建立後送出一次，
避免 join snapshot 與第一個 diff 的競態。

## Dirty Tracking

`@Sync` 會在寫入時標記 dirty，用於降低 diff 成本。
dirty tracking 每個 adapter 固定：由 `ENABLE_DIRTY_TRACKING`（預設開啟）設定。adapter 不會自行切換。

- 開啟：只序列化 dirty 欄位
- 關閉：每次同步都全量 snapshot

## 手動同步

在 handler 內可透過 `ctx.requestSyncNow()`（或 `ctx.requestSyncBroadcastOnly()`）請求 deterministic 的同步。
