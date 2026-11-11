[English](README.md) | [中文版](README.zh-TW.md)

# Transport

Transport 層將網路連線與 LandKeeper 串接，核心目標是「不把網路細節暴露給 Land DSL」。

## 設計重點

- Land 層只關心 `LandContext` 與 handlers，不知道 WebSocket/HTTP 細節
- Transport 層負責連線管理、訊息序列化與路由
- 同步採 snapshot + diff，避免阻塞 state mutation

## 資料流

```
Client ↔ WebSocketTransport ↔ TransportAdapter ↔ LandKeeper
```

## 三層識別

- `playerID`：帳號/玩家身分（業務層）
- `clientID`：裝置或 client instance（應用端提供）
- `sessionID`：連線層識別（server 產生）

這三層識別會進入 `LandContext`，讓 handler 有一致的使用介面，
也支援多裝置、多連線的行為控制。

## 核心組件

- Transport protocol：抽象連線行為（start/stop/send）
- WebSocketTransport：預設 WebSocket 實作
- TransportAdapter：解析訊息並呼叫 LandKeeper
- LandManager / Registry：管理多房間
- LandRouter / LandRealm：跨房間路由與控制

若要將 SwiftStateTree 與其他 HTTP/WebSocket 框架（如 Vapor、Kitura）整合，請參閱 [Server 整合指南](server-integration.zh-TW.md)。JWT 驗證、Guest 模式與 admin API key 請參閱 [JWT 與 Guest 模式](auth.zh-TW.md)。

## Join 與 Session 流程

- client 必須明確送出 join request
- join 會建立 `PlayerSession`，並依序執行 `CanJoin` / `OnJoin`
- 初次加入會回傳 snapshot，後續由 `StateUpdate`（firstSync/diff）接續
- session 仍在加入中時送給它的 targeted event（指定 session、client 或 player）會先保留，在它的 firstSync 之後依送出順序立即送達。broadcast event 不保留：firstSync 已經反映了它們。這在 in-turn sync 開啟時成立（`IN_TURN_SYNC`，預設開啟）。
  - 每個加入中的 session 最多保留 256 個 event／256 KiB（`JOIN_HELD_EVENTS_MAX`、`JOIN_HELD_EVENTS_MAX_BYTES`）。超過時 join 以 `JOIN_EVENT_OVERFLOW` 失敗，session 會被關閉；client 重新連線後取得全新的狀態。
  - 保留的 event 所描述的效果已經包含在 firstSync 裡。server event 是通知，同步的狀態才是真實來源：把 event 當成增量套用到自身狀態的 client 會重複計算。
- client 在 join 完成期間送出的 frame（action、client event），不論在 JoinResponse 之前或剛收到之後，都會在 OnJoin 之後依送出順序套用。in-turn sync 開啟時，它們會等到 JoinResponse 與 firstSync 送出後，再逐一執行；之後的 frame 排在它們後面。
  - 每個 session 最多等待 256 個 frame／256 KiB（`JOIN_DEFERRED_INBOUND_MAX`、`JOIN_DEFERRED_INBOUND_MAX_BYTES`）。join 完成前超過時，join 以 `JOIN_INBOUND_OVERFLOW` 失敗；完成後、先前的 frame 仍在套用時超過，session 會收到 `INBOUND_OVERFLOW`。兩種情況 session 都會被關閉，因為 client 遺失了自己送出的 frame：它需重新連線並再次 join。
- 會關閉 session 的 join 錯誤（`JOIN_INBOUND_OVERFLOW`、`INBOUND_OVERFLOW`、`JOIN_EVENT_OVERFLOW`，以及逾時或失敗的 join 的 `JOIN_DENIED`）會先寫入連線再關閉，最多等待 `FINAL_FRAME_CLOSE_TIMEOUT_MS`（預設 1000）。這保證的是交付順序：已停止讀取的 client 仍可能收不到該錯誤。沒有實作 `closeSessionAfterQueuedFrames` 的自訂 `Transport` 會立即關閉，可能遺失該錯誤。

### 連線

- **每個連線一個 `SessionID`。** transport、router 與 adapter 的每個 per-session map 都以它為 key，因此 `WebSocketTransport.handleConnection` 的呼叫端必須為每個連線傳入新的 ID（NIO server 為每個連線產生 UUID）。
- `handleConnection` 會拒絕 ID 仍被占用的連線：仍在連線中、正在斷線（直到 delegate 的清理返回），或已被 server 關閉但尚未確認。它回傳 `.rejected(.sessionIDInUse)`、關閉該連線、不呼叫 `onConnect`，並計入 `connectionsRejectedSessionIDInUse`。被拒絕之後，呼叫端不得再為該連線呼叫 `handleIncomingMessage` 或 `handleDisconnection`：兩者都會作用在占用該 ID 的 session 上。
- **每個 session 依序遞送。** 一個 session 的 frame 會逐一送到 `TransportDelegate.onMessage`，每次都在前一次呼叫返回之後（NIO server 的 inbound chain 即如此）。join 的 frame 延後機制依賴這一點。
- **被停止的 land**（`LandServerProtocol.stopLand`，即 admin DELETE，#102）會在每個 session 的 leave 執行完後，以 **4014**（land stopped）關閉它們，附 500 ms 的關閉寬限。與 1001 不同，它表示是這個 land 不在了，而不是 server：client 不會自行重試同一個 join。之後以該 land ID join 會在被停止的 instance 銷毀後得到新的 instance（有 auto-create 時）。仍在 join 該 land 的 session 會被拒絕（`JOIN_DENIED`，可重試）。4013 保留不用。

PlayerSession 欄位優先序：

1. join request 內容
2. JWT payload
3. guest session

## 同步模型

- snapshot：完整狀態（含 per-player 過濾）
- diff：只傳變更（path-based patches）
- firstSync：玩家首次建立 cache 後送出一次

### Broadcast 與 Per-Player 更新

每個 session 每個 sync cycle 的 frame，依此順序（outbound writer 會維持順序）：

- **opcodeMessagePack**：合併的 broadcast frame（opcode **107**：broadcast diff 對所有 session 只編碼一次，加上 broadcast events），接著是該 session 的 targeted event frame，最後是它的 per-player state frame（opcode 0/1/2）。只有在 broadcast diff 非空或有排隊中的 event 時才會送 107 frame；只改變 per-player 狀態的 cycle 只送 per-player frame。
- **jsonObject / opcodeJsonArray**：每個 session 一個合併的 state frame。Event 不合併；每個 event 在送出（emit）時即傳送。
- **firstSync**：單一合併更新（該玩家的完整狀態）。

晚加入者（#189）：使用合併 broadcast frame 時，broadcast dynamic-key 表由 land 的所有 session 共用。當 joiner 的 firstSync 在一個含 state patch 的 107 frame 之後 commit，下一個 cycle 會為所有成員重設 key scope：該 frame 標記為 firstSync 並重新定義它用到的 key，因此 joiner 不會看到在它加入前定義的 slot。代價是每次 join 後第一次同步每位成員約 13 bytes，加上每個 key 重新定義一次；broadcast 表為空，或 encoder 不保留 key 表（關閉 dynamic-key compression 或 path hashing）時不會重設。

## 錯誤處理

- join/action/event 錯誤會回傳 `ErrorPayload`
- join 會檢查 landID 與 session 狀態，避免重複加入或錯誤路由

## 多房間支援

- `LandManager` 管理 Land lifecycle 與查詢
- `LandRouter` 負責將連線導向對應 land
- multi-room 模式下 join 會依 landType + instanceId 進行路由

## 狀態更新編碼（State Update Encoding）

| `TransportEncodingConfig` | Message | State update | 預設於 |
|---|---|---|---|
| `.json` | `json` | `jsonObject` | `NIOLandServerConfiguration.transportEncoding`；DemoServer（`TRANSPORT_ENCODING=json`） |
| `.jsonOpcode` | `json` | `opcodeJsonArray` | `TRANSPORT_ENCODING=jsonOpcode` |
| `.opcode` | `opcodeJsonArray` | `opcodeJsonArray` | `TRANSPORT_ENCODING=opcode` |
| `.messagepack` | `messagepack` | `opcodeMessagePack` | GameServer（`TRANSPORT_ENCODING=messagepack`）；建議用於正式環境 |

`TransportEncodingConfig(message:stateUpdate:)` 本身預設為 `json` message 搭配 `opcodeJsonArray` state update；在每種使用 path hash 的 opcode state update 編碼中，dynamic-key compression 預設開啟。兩個範例 server 都讀取 `TRANSPORT_ENCODING`（`json`、`jsonOpcode`、`opcode`、`messagepack` 或 `msgpack`，不分大小寫）；無法辨識的值會回退為 `json`。

### Atomic 值

採用 `AtomicSnapshotValue` 的型別（`IVec2`、`IVec3`、`Position2`、`Velocity2`、`Acceleration2`、`Angle`，以及用 `@SnapshotConvertible(atomic: true)` 宣告的使用者 struct）在 diff 中是單一值，不會逐 leaf 比對。只有宣告會讓型別成為 atomic；只是長得像 `{x, y}` 的 struct 仍逐欄位 diff。

- **Opcode state update**（`opcodeJsonArray`、`opcodeMessagePack`）把 atomic 值送成其 leaf 的陣列，順序為 schema 的 `leafOrder`：`Position2` 是 `[x, y]`，`Angle` 是 `[degrees]`，皆為定點整數。不論值位在何處都一樣：欄位、陣列元素、map 的值、optional、以上任一處裡的 struct，以及新增物件或 firstSync snapshot 之內。MessagePack 中一個 `Position2` patch 值為 11 B（原本 18 B），`Angle` 為 6 B（原本 14 B）。
- **`jsonObject` state update 與 server event 維持 keyed**（`{"v": {"x": ..., "y": ...}}`）。
- **邏輯形式不變：** `StatePatch`、`SnapshotValue`、state hash 與 sync-output hash 都是 keyed，所以紀錄及其驗證與線上格式無關。
- **開關：** `TransportEncodingConfig.atomicValues` 預設為 `.positional`；`.keyed`（`withAtomicValues(.keyed)`）讓 opcode state update 也送 keyed 值，保留一個版本，給無法與 server 同步更新的 client。
- **Schema 宣告格式：** schema 根節點帶 `"x-stateTree": {"atomicEncoding": "positional"}`，每個 atomic 定義帶其 `leafOrder`，兩者都計入 schema hash。這個標記表示 client 必須能解碼的格式，所以在 `.keyed` 下也是 `positional`。SDK view 能解碼 positional 與 keyed 值，拒絕不認得的 `atomicEncoding`，並接受沒有標記的 schema。
- **Schema hash 與舊 client：** positional atomic 值之前建置的 client，schema hash 不同。開啟 `expectedSchemaHash` 時它會在 join 被拒，而不是把 `[x, y]` 當成普通陣列保留。為這類 client 執行 `.keyed` 的部署，在它們更新前保持 `expectedSchemaHash` 關閉。本 repository 的 SDK 與 server 一起發佈：兩者需一起更新。
- 位在 atomic 路徑、但 key 不完全等於其宣告 leaf 的值無法編碼；該 patch 走 adapter 既有的 unencodable-patch 路徑，不會送出。

### Path index

開啟 `TransportEncodingConfig.pathIndex`（預設開啟；`withPathIndex(false)`，或在 Demo 與 Game server 設 `PATH_INDEX=false` 可關閉）時，使用 path hash 的 opcode state update 對每個 patch 的 pattern 改送其 **path index**，而不是 32-bit hash。path index 是該 hash 在 land 的 schema `pathHashes` 值（去重、遞增排序，`PathHasher.sortedHashes`）中的位置。

- **id 更小：** pattern 少於 128 個的 land，MessagePack 中 index 為 1 byte（hash 佔 5 B），JSON 中為 1–3 位數（hash 為 9–10 位）。
- **schema 不變：** server 與 client 由共用的 schema 推得此表。schema、其 hash 與 codegen 輸出都不變。
- **預設開啟。** SDK 與負載工具在 join 時宣告 `pathIndex`。server 開啟時，沒有宣告的 client 會被拒絕。
- **沒有 path hash 時**，opcode encoder 送字串路徑，因此 index 實際上是關閉的（`effective(pathHashes:)`），也不要求 client 宣告。
- **schema 之外的路徑**沒有 index，該 patch 無法送出。套用 adapter 既有的無法編碼 patch 處理（與無效的 atomic 值相同）：丟掉該 patch，其餘的 update 照常送出，該 scope 在 sync stream 中標為無法驗證，該欄位下次變動時會再送到 client。`TransportAdapter.unmappedPathPatches` 計算被丟掉的 patch 數，每個新 pattern 記一次 log。
- **紀錄維持邏輯形式：** index 在 encoder 中決定，位於 sync plan 之後。紀錄、sync-stream hash 與 sync-output golden 都不變。

**Handshake。** schema hash 不變，因此舊 client 會把 index 當成 hash 讀。client 在 join metadata 中（與 `schemaHash` 並列）宣告它能解碼的 state-update feature：`"stateUpdateFeatures": ["pathIndex"]`。

- 開啟 index 的 server 會拒絕沒有宣告它的 join，回 `JOIN_STATE_UPDATE_FEATURE_MISSING` 與 `unsupported state update encoding: missing pathIndex`。router 在查找或建立 land 之前檢查。
- `joinResponse` 回傳使用中的 feature（`stateUpdateFeatures`），client 依此解碼。沒有任何 feature 開啟時不帶此欄位。
- index 關閉時，沒有宣告的 client 照舊 join。client 宣告的比 server 使用的多也沒問題。
- 本 repository 的 SDK 會宣告 `pathIndex`、`fieldMerge`、`syncSequence` 與 `rowAddressing`（`SUPPORTED_STATE_UPDATE_FEATURES`），Swift client 用 `StateUpdateFeature.joinMetadata` 也一樣。`Tools/CLI` 透過 SDK 解碼。`ws-loadtest` client 在每次 join 都宣告前三項，`rowAddressing` 只在 `--row-addressing on` 時宣告（預設 off）：這項宣告屬於 join metadata，會被錄製中的伺服器寫進 record，因此不加這個 flag 的執行送出的 join 與先前相同。預計在 row addressing 成為伺服器預設後，把這個 flag 的預設改為 on。它的執行摘要會記錄這個 flag（`runConfig.rowAddressing`）、每次 join 協商到的 features（`stateUpdateFeatures`）與 client 收到的 row entry 數（`rowEntries`），因此可以分辨 row addressing 有生效與沒有生效的執行。

### Field merge

開啟 `TransportEncodingConfig.fieldMerge`（預設開啟；`withFieldMerge(false)`，或在 Demo 與 Game server 設 `FIELD_MERGE=false` 可關閉）時，使用 path hash 的 opcode state update 會把同一個 frame 中、對同一個 parent（且 dynamic key 相同）的欄位做 set（或 add）的 patch，合併成**一個 merged entry**：`[parentId, dynamicKey, op, fieldMask, v1, v2, …]`。

- **op** 為 4（每個欄位 set）或 5（每個欄位 add）。**parentId** 是 parent 的 path id：其 hash，開啟 `pathIndex` 時則為其 path index。
- **mask：** 欄位的 bit 是它在 parent 具名子節點（pattern `parent.<name>`，name 不為 `*`）中、依名稱 UTF-8 byte 順序排序後的名次。值依 bit 遞增排列，每個設定的 bit 一個值。只用到 bit 0–6 的 mask 在 MessagePack 中是 1 byte 的 fixint。
- **可合併的欄位**是 leaf 與 atomic 值（`FieldMergeTable`）。名次 32 以上的欄位、delete、底下還有欄位的 object set，以及 schema 之外的路徑，都維持一般 entry。mask 為 32 bit，因為 JavaScript client 只能精確讀到 2^53 以內的整數，且其位元運算子是 32 bit。
- **順序：** merged entry 佔它第一個成員的位置。位於 parent 路徑本身、其上或其下的 patch（entity 的 delete 或 set、其 map 被取代、兄弟欄位被 delete）會關閉該 group，之後的欄位另開新 entry，套用順序與一般 frame 相同。其他 entity 的 patch 不會關閉它。
- **紀錄維持邏輯形式**，與 path index 相同：合併在 encoder 中進行，位於 sync plan 之後。
- **Handshake：** 開啟合併的 server 要求 join 的 `stateUpdateFeatures` 包含 `fieldMerge`，方式與 `pathIndex` 相同；缺少清單會列出所有缺少的 feature（`missing pathIndex, fieldMerge`）。沒有 path hash 時，合併實際上是關閉的。

### Row addressing

開啟 `TransportEncodingConfig.rowAddressing`（預設關閉；`withRowAddressing(true)`，或在以 `TransportEncodingConfig.rowAddressingFromEnvironment()` 建立設定的 server 設 `ROW_ADDRESSING=true`）時，opcode state update 以 **slot** 而非 key 指稱 slot-addressed table 的 row。slot-addressed table 是位於 root、把 key 對應到 state node 的 broadcast 欄位（`[String: Unit]`）。

- **Entry**（`RowPatchOpcode`）：
  - create `[tableId, slot, 6, generation, null, key, value]`：一個完整的新 row；此後該 slot 綁定到這個 key；
  - delete `[tableId, slot, 7]`：移除該 row 及其下所有內容，slot 釋出；
  - column set `[leafPathId, [slot, …], 8, [value, …]]`：在這些 row 設定同一個 leaf，slot 遞增；
  - column clear `[leafPathId, [slot, …], 9]`：在這些 row 移除同一個 leaf。
  - **tableId** 是 row pattern（`units.*`）的 path id，**leafPathId** 是 leaf（`units.*.hp`）的 path id。其他 patch 在同一 frame 中維持現有形式。
- **Slot 與 generation：** 釋出的 slot 之後會被新的 create 再次使用，generation 加一。client 會拒絕：指向未綁定 slot 的 entry、在已綁定 slot 上的 create、generation 沒有大於該 slot 上一次的 create，以及任何不是範圍內精確整數的 slot、op 或 generation。
- **第一份 view**（joiner 的或 resync 的）把每個 slot-addressed table 送成 `{}` 加上每個 row 一個 create，讓 client 得知所有綁定。
- **無法編碼的 row**（opcode JSON 中的非有限數）整個從 frame 中拿掉：它的 create、它在 column 中的成員，以及它底下的所有 patch。table 的其餘部分照常送出，該 row 在之後每次 sync 重新 diff，直到送出為止。被拿掉的 scope 在 sync stream 中標為無法驗證。
- **紀錄維持邏輯形式：** row entry 在 encoder 中產生，位於 sync plan 之後，因此不論開關，紀錄與 sync-stream hash 都相同。
- **實際生效**需要 path hash、`pathIndex`、`syncSequence`、opcode encoding、delta strategy、in-turn sync（預設）以及經由 router 的 join（有 shared transport 的 `LandManager`，NIO hosting 即是）。否則關閉並記錄 warning。它會開啟 sync tables（`USE_SYNC_TABLES`），slot table 存在其中。replay land 不使用它。
- **Handshake：** 實際啟用 row addressing 的 land 會在查找 land 之後拒絕沒有宣告 `rowAddressing` 的 join，回 `JOIN_STATE_UPDATE_FEATURE_MISSING`。TypeScript SDK 與使用 `StateUpdateFeature.joinMetadata` 的 Swift client 會宣告它；`ws-loadtest` client 在 `--row-addressing on` 時宣告它。
- **違反規則會關閉連線（TypeScript SDK）。** client 拒絕的 row entry（見上），或未協商 `rowAddressing` 就收到的 row entry，表示 client 的 view 已不可信。SDK 不會丟掉該 frame 繼續，而是以 **4013**（`invalidRowEntry`，由 client 送出，reason 為 `row entry: <rule>`，最多 123 個 UTF-8 位元組）關閉連線：
  - 每個 view 的 `onError` 收到 source `'decode'`、code `INVALID_ROW_ENTRY` 與 `details.rule`；
  - 連線上仍在排隊的 frame 會被丟棄而不套用，並計入 `decodeErrorStats().droppedAfterStrictClose`；
  - 之後的關閉與其他關閉相同：銷毀 view 並呼叫 `onDisconnect`。SDK 不會自行 rejoin；rejoin 會從新的 firstSync 開始。
  - 自訂的 WebSocket factory（`registerWebSocketFactory`）必須把 `close(code, reason)` 傳給它的 socket：忽略這兩個參數的實作會以 1005（無狀態碼）關閉，server 不會看到 4013。

  join response 帶有 `rowAddressing` 卻沒有 `pathIndex` 時，以同樣方式關閉，並拒絕該 join。其他解碼錯誤（dynamic-key slot 在定義前被使用）仍是丟掉該 frame 後繼續；`disconnect()` 之後的錯誤只計數。Swift 的 `SessionClose.Code` 為此關閉保留 4013。`ws-loadtest` client 也以同樣方式關閉，記錄這次關閉（cause 為 `rowEntry`，附上違反的規則）並計數（`rowEntryCloses`）。沒有 `--reconstruct` 時，它只檢查 row entry 是否在協商到該功能時才出現：其他規則需要 land 的 pattern，只有 SDK 的 decoder 有。兩個 decoder 都接受 `7.0` 或 `1e2` 這類整數值的字面值。差別在於落在某個整數的 double 捨入範圍內的字面值，例如 `7.0000000000000000001`：Swift decoder 會拒絕，而 `JSON.parse` 在 SDK 看到之前就已把它捨入成 7，因此 SDK 會接受。這是 JavaScript 數字解析的限制。encoder 不會寫出這類字面值。
- **Row table（TypeScript SDK）** 以連線為單位：在連線開啟、每次 join response（同一 socket 上的 rejoin 會收到上一個 land 綁定過的 slot 的 create）與每次 resync 時重新開始，key-scope reset 時不重來。resync 之後，帶有該 resync sequence 的 frame 仍會套用其中的 row entry，以及 resync 套用當下有已綁定 row 的 root 底下的所有 patch：快照中的這些 table 是已提交的狀態，而非即時狀態。該 frame 的其他 patch 照常略過，與未開啟 row addressing 時相同。


一個 frame 的 bytes 只取決於內容，與 dictionary 的走訪順序無關（Swift 每個 process 的 hash seed 不同）。adapter 送出的每個 state update，其 patch 都依同一個 canonical order 排列，順序在規劃 field merge 與 dynamic-key slot 之前就決定。（單獨使用的 encoder，例如 `makeStateUpdateEncoder` 建立的或自訂的，維持輸入的順序。）

- **Table：** 從 land 的 state 可到達的每個 `StateNodeProtocol` 型別各是一個 table，依 parent 優先編號（root 為 0），平手時依深度優先走訪（欄位依 UTF-8 名稱順序）第一次遇到的順序。遞迴的 state 型別（schema 產生會拒絕）仍有確定的順序，但 cycle 上及其下的 table 排在最後，因此 parent 的 table 可能排在 child 之後。
- **Patch 的 key** 是 `(table, chain, field, sub-key path)`：所指 row 的 table、從 root 到該 row 的 `(field, key)` 序列、寫入的欄位（set 或 delete 整個 row 時沒有）、以及該欄位以下的路徑元件。比較時先比 table，再逐元件以 UTF-8 bytes 比較，前綴在前，所以 row 本身的 patch 排在其欄位 patch 之前。
- **物件 key：** JSON state update 與 JSON transport message 以排序後的 key 寫出（`JSONEncoder` `.sortedKeys`，UTF-8 byte 順序）；MessagePack map 的字串 key 依 UTF-8 byte 順序打包，其他 key 依打包後的 bytes 排序（打包後 bytes 相同的兩個 key，例如 `.int(1)` 與 `.uint(1)`，彼此順序不固定）。

diff 不會在同一 frame 裡同時送出一個路徑與它的祖先路徑，所以排序不會改變相依 patch 的先後。Client 依收到的順序套用 patch，不需要修改。

狀態更新在每個 sync 週期內以串行方式編碼。同一房間內每位玩家的更新依序編碼；多房間場景下，每個 `TransportAdapter` 獨立管理一個房間。

## 環境變數

Transport 相關行為可透過環境變數調整。所有變數在 `TransportAdapter` 初始化時讀取。完整清單與解析規則見 `TransportEnvConfig`（SwiftStateTreeTransport 模組）。

| 變數 | 型別 | 預設 | 說明 |
|------|------|------|------|
| `ENABLE_DIRTY_TRACKING` | Bool | init 參數 | 啟用 dirty-field 追蹤以產生較小 diff；高更新比例場景可關閉 |
| `USE_SNAPSHOT_FOR_SYNC` | Bool | true | 使用單次 snapshot 擷取；設為 `false` 使用舊版 broadcast + per-player 路徑 |
| `USE_SYNC_TABLES` | Bool | false | 實驗性：broadcast 欄位改在 typed sync tables 上做 diff，不經 snapshot（僅 delta 策略）。兩種方式送出的 frame 位元組相同。同步值型別須遵守的規則見 [Sync](../core/sync.zh-TW.md#同步值型別的規則) |
| `SYNC_STRATEGY` | String | `delta` | `delta` 只送變更欄位；`full-snapshot` 每次同步送每個接收者的完整視圖（量測用基線，非正式模式） |
| `ENABLE_CHANGE_OBJECT_METRICS` | Bool | false | 記錄被量測的 sync 的 changed vs unchanged 物件比例（見 `AUTO_DIRTY_SAMPLE_EVERY`） |
| `CHANGE_OBJECT_METRICS_LOG_EVERY` | Int | 10 | 變更物件 metrics 日誌之間隔幾次被量測的 sync |
| `CHANGE_OBJECT_METRICS_EMA_ALPHA` | Double | 0.2 | 每次 sync 的變更率 EMA alpha（0.01–1.0）；依採樣間隔換算 |
| `AUTO_DIRTY_TRACKING` | Bool | true | 依變更率遲滯曲線自動切換 dirty tracking |
| `AUTO_DIRTY_OFF_THRESHOLD` | Double | 0.55 | 關閉 dirty tracking 的 EMA 門檻 |
| `AUTO_DIRTY_ON_THRESHOLD` | Double | 0.30 | 開啟 dirty tracking 的 EMA 門檻 |
| `AUTO_DIRTY_REQUIRED_SAMPLES` | Int | 30 | 模式切換前需連續越過門檻的 sync 次數（無條件進位到整數次採樣） |
| `AUTO_DIRTY_SAMPLE_EVERY` | Int | 1 | 每 N 次 sync 量測一次變更率（限制在 1–1024）；1 表示每次都量測。大於 1 時採樣相位固定，若工作負載的忙碌 sync 以能整除 N 的週期重複，每次都會量到週期中的同一點 |
| `TRANSPORT_PROFILE_JSONL_PATH` | String | 關閉 | 設定後啟用 transport profiling，將 JSONL 寫入此路徑 |
| `TRANSPORT_PROFILE_INTERVAL_MS` | Int | 1000 | Profiling 寫入間隔 (ms)，最小 100 |
| `TRANSPORT_PROFILE_SAMPLE_RATE` | Double | 0.01 | Latency 採樣率 (0.001–1.0) |
| `TRANSPORT_PROFILE_MAX_SAMPLES_PER_INTERVAL` | Int | 500 | 每間隔最大 latency 採樣數 (10–10000) |
| `OUTBOUND_WRITER_MAX_BYTES` | Int | 67108864 (64 MiB) | 每個 land 的 outbound writer 排隊位元組上限（最小 1024）。超過上限的 frame 會被丟棄，受影響的 session 會被斷線 |

由其他地方讀取：

- `PATH_INDEX`（Bool，預設 true）：使用 path hash 的 opcode state update 改送 path index 而非 hash。見 [Path index](#path-index)。只有以 `TransportEncodingConfig.pathIndexFromEnvironment()` 建立 encoding 設定的 server 會讀取（Demo 與 Game server 皆有），以及 `EncodingBenchmark`（`--path-index on|off`）。
- `FIELD_MERGE`（Bool，預設 true）：使用 path hash 的 opcode state update 把同一 parent 的欄位 patch 合併成一個 entry。見 [Field merge](#field-merge)。只有以 `TransportEncodingConfig.fieldMergeFromEnvironment()` 建立 encoding 設定的 server 會讀取（Demo 與 Game server 皆有），以及 `EncodingBenchmark`（`--field-merge on|off`）。
- `DYNAMIC_KEY_COMPRESSION`（Bool，預設 true）：使用 path hash 的 opcode state update 在 dynamic key 第一次使用後改送 table slot（true），或一律送完整字串（false）。只有以 `TransportEncodingConfig.dynamicKeyCompressionFromEnvironment()` 建立 encoding 設定的 server 會讀取（Demo 與 Game server 皆有）。
- `ROW_ADDRESSING`（Bool，預設 false）：opcode state update 以 slot 指稱 root node map 的 row。見 [Row addressing](#row-addressing)。以 `TransportEncodingConfig.rowAddressingFromEnvironment()` 建立 encoding 設定的 server 會讀取，Demo 與 Game server 都是。只在有 path hash 的 land（GameServer 的）生效；CI 會在兩種 opcode encoding 下開啟它執行 GameServer E2E。
- `SYNC_LAG_RESYNC_MS`（預設 3000）、`SYNC_ACK_FRESHNESS_MS`（2000）、`SYNC_ACK_TIMEOUT_MS`（10000）、`SYNC_LAG_SLOW_CONSUMER_COUNT`（3）與 `SYNC_LAG_SLOW_CONSUMER_WINDOW_MS`（60000）（Int；`SyncLagPolicy.fromEnvironment()`，為 `NIOLandServerConfiguration.syncLag` 與未傳入 policy 的 `TransportAdapter` 的預設值）：同步延遲的門檻。缺少、非整數或非正數時使用預設值。
- `SYNC_LAG_CLOSE_GRACE_MS`（Int，預設 2000；`SyncLagPolicy.closeGrace`）：4010、4011 與 4012 關閉的關閉寬限。0 表示關閉此功能；非整數或負數時使用預設值。
- `WS_PONG_TIMEOUT_MS`（Int，預設 20000；NIO hosting，`NIOWebSocketServerConfiguration.pongTimeout`）：server 每 30 秒 ping 每個 WebSocket session 一次，各 session 有自己的相位。ping 之後這麼多毫秒內若沒收到對端任何 frame（pong 或任何訊息都算），server 以 1001（going away）關閉連線。計時從 ping 寫入 channel 起算，所以排在慢速讀取端積壓之後的 ping 也會計入。須為正數且小於 30000；其他值使用預設值。
- `WS_SEND_BACKLOG_MAX_BYTES`（Int，預設 8388608 = 8 MiB）與 `WS_SEND_BACKLOG_MAX_UNWRITABLE_MS`（Int，預設 30000；NIO hosting，`NIOWebSocketServerConfiguration.sendBacklogBound`）：送出積壓上限（#61），見[送出積壓上限](#送出積壓上限)。0 停用該上限；負數或非整數使用預設值，並記錄警告。
- `WS_INBOUND_BACKLOG_MAX_MESSAGES`（Int，預設 1024）與 `WS_INBOUND_BACKLOG_MAX_BYTES`（Int，預設 4194304 = 4 MiB；NIO hosting，`NIOWebSocketServerConfiguration.inboundBacklogBound`）：接收積壓上限（#113），見[接收積壓上限](#接收積壓上限)。0 停用該上限；負數或非整數使用預設值，並記錄警告。
- `IN_TURN_SYNC` 與 `LAND_LOOP_PHASE_OFFSET`（runtime，預設開啟）：見 [Runtime](../core/runtime.zh-TW.md#in-turn-sync預設)。
- `RESOLVER_TIMEOUT_MS`（Int，預設 5000）與 `RESOLVER_INIT_TIMEOUT_MS`（Int，預設 30000；runtime）：一組 resolver 的期限，以及 OnInitialize 的期限；0 停用。見 [Resolver 期限](../core/resolver.zh-TW.md#期限)。
- `ACTION_IN_FLIGHT_MAX_PER_SESSION`（Int，預設 8）與 `RESOLVER_ABANDONED_ACTIONS_MAX`（Int，預設 256；runtime）：單一 session 仍在 resolver 中的 action 上限，以及整個 process 被放棄者的上限；0 表示不設上限。見 [帶 resolver 的 action](../core/resolver.zh-TW.md#帶-resolver-的-action)。
- `JOIN_TIMEOUT_MS`（Int，預設 12000；0 停用；負數或非整數使用預設值）：join 的端到端時限（#104）。從 join 請求起算，涵蓋 land 查找或建立，以及在 land membership 佇列中的等待，直到 keeper 的 join 開始為止；在 turn 內完成的 join，其 flip 之後等待的是剩下的時限。超過時限的 join 會收到 `JOIN_DENIED` "Join timed out"，後接所在階段（`during land lookup`、`waiting for admission` 或 `waiting for the flip`），作為最後一個 frame，session 隨後關閉；重試要用新連線。客戶端的 join 逾時要大於它（CLI 為 15 秒，`CLI_JOIN_TIMEOUT_MS`），客戶端才會先收到錯誤。不經 router、直接透過 `TransportAdapter.performJoin` 的 join，從 admission 起算時限，用於 flip 的等待。
  - **已開始的 keeper join 不受此時限限制**（#241）。逾時只作用於尚未開始的 admission。已在 keeper join 中的會讓它完成，因為中斷它會破壞 membership 佇列的順序。它自己的上限是 resolver 時限：CanJoin、同一玩家被取代之 session 的 OnLeave，以及 OnJoin，每組最多 `RESOLVER_TIMEOUT_MS`（5 秒），合計最多 15 秒。land 的第一個 join 中，keeper 的 join 還要等 land 初始化，最多 `RESOLVER_INIT_TIMEOUT_MS`（30 秒）。因此最壞情況是 keeper join 開始前花掉的時間（小於時限），加 15 秒，第一個 join 再加 30 秒，超過 CLI 的 15 秒。已開始的 join 之後，turn 內的 flip 等待剩下的時限，可能已經是零；legacy 路徑沒有 flip 等待。
  - **flip 自己的逾時是下限。** 它經過 land 的 membership 佇列，排在前面的工作可能延後它。
  - **其他關閉可能先到。** join 被 admit 之後，session 也可能在 flip 等待結束前就被結束：客戶端在等待期間送出超過 join 的 inbound 上限時的 `JOIN_INBOUND_OVERFLOW`，或 keepalive 的 pong 逾時（`WS_PONG_TIMEOUT_MS`，close code 1001），後者不送錯誤 frame。因此未完成的 join，客戶端不一定會看到 `JOIN_DENIED`。
- `JOIN_FLIP_TIMEOUT_MS`（已棄用，將移除）：請改設 `JOIN_TIMEOUT_MS`。若有設定，它仍會在時限內限制 flip 的等待，router 並記錄棄用警告。
- `LAND_LIFECYCLE_LOG_PATH`（String，預設未設定：不記錄）：每個 `LandManager` 在此檔案為每個 land 實例的事件附加一行 JSON（`LandLifecycleRecord`）。事件有：
  - `created`：實例發布時；
  - `removed`：依 ID 移除時，例如 admin API 的刪除。實例保留其玩家，之後才被銷毀。
  - `destroyed`：銷毀結束時，附 `cause`：`emptyTimeout`、`forceShutdown` 或 `initializationFailed`。

  每行帶 land ID 與類型、process 內單調遞增的 `instance` 編號、manager 的 `epoch`、`wallMs`（1970 起的毫秒，與 profile 的 `ts` 同基準）與 `uptimeNs`（`ProcessInfo.systemUptime`，單調時鐘）。同一 ID 重建的 land 會得到新的 `instance`。此 log 不經 logger 的等級過濾，所以在 `LOG_LEVEL=error` 下也有效；每個事件只寫一次，tick 與 sync 不受影響。檔案以 `O_APPEND` 開啟，多個 process 可共用；各自的 instance 編號都從 1 開始。路徑無法開啟或寫入失敗（例如磁碟已滿）時，log 會停用並記錄一行 error，server 照常運作。

  同一檔案也記錄兩種 session 行（`SessionLifecycleRecord`）：
  - `sessionJoined`：land 的 adapter 在 join 完成時寫入，帶 `sessionID`、`playerID`、`landID` 與 land 的 `instance`。
  - `sessionClosed`：NIO session handler 在決定關閉時寫入，帶 `sessionID`、`cause`，以及有的話附關閉 `code`。

  原因有：
  - `pongTimeout`（1001）；
  - `backlogBytes` 與 `backlogUnwritable`（4008）；
  - `clientClose`：附 client 的 code；
  - `serverClose`：transport 要求的關閉，附其 code，涵蓋 join 錯誤、踢出與關機，不再細分。server 的 graceful shutdown（`NIOLandHost.shutdown()`、`runUntilShutdownSignal()`）會以 1001 Going Away 關閉它仍持有的每個 session，因此記為 `serverClose` 1001：與 pong 逾時同一個 code，但 cause 不同；
  - `connectionLost`：先前沒有決定任何關閉，channel 就斷了（EOF，或因 reset、broken pipe、逾時而失敗）；
  - `error`：server 因其他錯誤關閉，例如協定錯誤。

  每個 session 只有一行 `sessionClosed`，記錄最先決定的原因。
  - **對應方式：** 兩種行以 `sessionID` 對應，不論先後。NIO hosting 每次 WebSocket upgrade 都產生新的 UUID，所以每條連線唯一。關閉在連線的 event loop 上決定，而在它之前讀到的 join 可能之後才在 land 裡完成，所以 `sessionClosed` 可能出現在對應的 `sessionJoined` 之前。一個 session 可以 join 多次，它的關閉適用於同一 `sessionID` 的每一次 join。
  - **instance 編號** 在 land 建立時取得，`created` 則在發布時寫入。所以 `created` 行不依 `instance` 排序，從未發布（先被拆除）的建立會留下空號。
  - **檔案位置：** 放在本機磁碟。每一行都由 manager、adapter 或 event loop 同步寫入，慢的網路檔案系統會拖慢它們。

布林解析：truthy = `1`, `true`, `yes`, `y`, `on`；falsy = `0`, `false`, `no`, `n`, `off`。

## Profiling

設定 `TRANSPORT_PROFILE_JSONL_PATH` 後，adapter 每個間隔寫一行 JSON。除了訊息計數與 latency 採樣（`decode_ms`、`handle_ms`、`encode_ms`、`send_ms`），每行也計算該時窗的 sync cycle：

| 計數器 | 意義 |
|---|---|
| `syncCycles` | commit 了 plan 的 sync cycle（兩種路徑皆計）：其他計數器的分母 |
| `syncSkipsBacklog` | 因 writer back-pressure 而略過的 cycle |
| `syncDeferredTurns` | `syncSkipsBacklog` 中：因 back-pressure 而延後的 in-turn sync phase |
| `syncSkipsBusy` | 因已有 cycle 進行中而被拒的請求（legacy 路徑） |
| `syncFolds` | 併入下一個 tick turn 的 in-turn sync cycle（coincident sync），每個 cycle 最多一次 |
| `syncOverdueFolds` | `syncFolds` 中：其 tick 已逾時、frame 須等待遲到 tick 的併入 |
| `syncFailedPlans` | 拋出錯誤、什麼都沒 commit 的 sync plan |
| `syncDroppedUpdates` | 因無法編碼或擷取而被丟棄的 patch、update 或欄位 |

Sync 階段時間：`sync_extract_ms`、`sync_broadcast_ms` 與 `sync_perplayer_ms`，各為該視窗內完整 sync plan 的 `{sum, plans, mean}`。三者分別涵蓋 snapshot 擷取、broadcast diff 與 per-player diff。擷取以一次呼叫同時產出 broadcast 與 per-player snapshot，因此不拆分給兩者。編碼、frame 規劃與 joiner 的完整 view 不計入任何一項。diff 工作中 broadcast 的占比為 `sync_broadcast_ms / (sync_broadcast_ms + sync_perplayer_ms)`。`sync_combined_plans` 計算沒有合併 broadcast frame 的 plan：其 per-player 時間包含把 broadcast diff 併入每位玩家 update 的工作，因此計算占比時要依此篩選，或註明所用模式。只有 profiling 開啟時才讀取時鐘。

每行也有 `pongTimeoutCloses`：keepalive ping 之後 `WS_PONG_TIMEOUT_MS` 內沒收到任何 frame 而被關閉的 WebSocket session 數（NIO hosting）。也有 `closeFrameTimeouts`：伺服器發起的關閉中，close frame 在 5 秒內沒寫出、因此不等它就關閉 channel 的次數。客戶端在 channel 仍可寫時停止讀取，就會出現這種情況（NIO hosting）。

優雅關閉時（`NIOLandHost.runUntilShutdownSignal()`），profiler 會再寫最後一行，內容是上一行之後的計數，並標上 `"final": true`，實際長度記在 `interval_ms`。它比完整的時間窗短，所以不要算進每個時間窗的次數與最大值。ws-loadtest 的讀取程式會整行略過它：它們的總數不含這最後一段不完整的時間窗，是整次執行的下限，只能和用同樣方式讀出的總數比較。

期限（#104）：`resolverTimeouts` 與 `resolverInitTimeouts`，超過 `RESOLVER_TIMEOUT_MS` 或 `RESOLVER_INIT_TIMEOUT_MS` 的 resolver 組數；`resolverInitFailures`，丟錯而使 land 初始化失敗的 OnInitialize resolver 組數（`.failLand`，#238）；`onLeaveDropped`，因 resolver 失敗或逾時而丟棄的 OnLeave 輸入數；以及依階段區分的逾時 join 數：`joinTimeoutsLandLookup`、`joinTimeoutsAdmission` 與 `joinTimeoutsFlip`。以上皆為該區間的計數。`abandonedResolvers` 是量表：呼叫端已不再等待（因期限或取消）但仍在執行的 resolver 組數。永不結束的 resolver 會讓它一直維持。`abandonedActions` 是只計 action 的同一種量表，`actionInFlightLimitRejections` 與 `actionAbandonedLimitRejections` 計數該區間兩個上限拒絕的 action 數。

送出積壓（NIO hosting，#61）的量測；超過[上限](#送出積壓上限)的 session 會被關閉：
- `sendBufferedBytesMax`：每個視窗內，任一 session 的 channel 在不可寫期間緩衝的最大位元組數（NIO 的 `bufferedWritableBytes`，已寫出但 socket 尚未接收）。只在超過寫入高水位（預設 64 KiB）時取樣：channel 轉為不可寫時取一次，之後仍不可寫期間每次寫入再取；0 表示沒有任何 channel 超過高水位。
- `sendUnwritableEpisodes`：視窗內 channel 超過寫入高水位的 session 次數。
- `sendUnwritableLongestMs`：這些時段中，在視窗內結束的最長一段。
- `sendUnwritableSessions`：gauge，不會每個視窗歸零：寫出該行時處於不可寫的 session 數。這是每個視窗結束時的取樣，不是峰值：在同一個視窗內轉為不可寫又恢復的 session，只會反映在 `sendUnwritableEpisodes`。

- `sendBacklogCloses`：視窗內被送出積壓上限關閉的 session 數。

接收積壓（NIO hosting，#113）；超過[上限](#接收積壓上限)的 session 會暫停讀取：
- `inboundQueuedMessagesMax`、`inboundQueuedBytesMax`：每個視窗內，任一 session 已讀入但尚未交給 transport 的最多訊息數（位元組數）。
- `inboundReadPauses`：視窗內 session 因達到上限而暫停讀取的次數。
- `inboundPausedLongestMs`：這些暫停中，在視窗內結束的最長一段。
- `inboundPausedSessions`：gauge，不會每個視窗歸零：寫出該行時正暫停讀取的 session 數。

ws-loadtest 會按階段在 "Server send backlog" 段落列出。

### 送出積壓上限

客戶端不讀取時，其 session 會被關閉（#61，選項 A），類似 Redis 的硬性 `client-output-buffer-limit`。任一上限都會關閉它：
- **位元組：** channel 在不可寫期間緩衝超過 `WS_SEND_BACKLOG_MAX_BYTES`。檢查點與積壓取樣相同（超過寫入高水位時，預設 64 KiB），所以低於高水位的上限要等 channel 超過高水位才會作用。單一 frame 若大於上限，即使客戶端正常讀取也會被關閉，所以上限要遠大於最大的 frame（例如大型狀態的 firstSync）；
- **時間：** channel 持續不可寫超過 `WS_SEND_BACKLOG_MAX_UNWRITABLE_MS`，從轉為不可寫時起算。恢復可寫或 session 結束時取消計時。

server 送出代碼 **4008** 的 close frame，並立即關閉連線，不等該 frame 寫出。已在進行中的 server 端關閉（例如 supersede、admin 關閉）不會讓上限失效：它的 close frame 可能排在同一批積壓之後，所以上限仍會關閉連線。這個 frame 排在 server 正在處理的積壓之後，所以不讀取的客戶端通常只會看到連線中斷（瀏覽器中為 1006），而非 4008。server 端的紀錄是可靠的：profile 中的 `sendBacklogCloses`，以及一行包含 session、上限與超出值的警告日誌。

客戶端重新連線並再次 join 即可重建：新的 view 從空狀態開始，其 firstSync 就是該玩家的完整視角（見 SDK 的[傳遞語意](../sdk/README.zh-TW.md#傳遞語意至多一次at-most-once)）。等待中的 action 會被 reject，結果未知。

積壓且不送任何訊息的客戶端，也可能在 30 秒時間上限之前先觸發 pong timeout（`WS_PONG_TIMEOUT_MS`，20 秒），因為 keepalive ping 排在積壓之後。兩者都會關閉連線；`pongTimeoutCloses` 與 `sendBacklogCloses` 可區分兩者。

### 同步延遲與就地重送（resync）

每個 hosted land 都會追蹤同步延遲：server 會依 client 自己回報的 ack，追蹤每個 client 落後已送出狀態多少（#332）。送出積壓上限是針對不再讀取的 client 的最後手段；這套機制更早介入，而且 client 仍保持連線、不需重連。

- **序號。** 每個 sync plan 取用 land 的下一個同步序號，該 plan 的每個 state-update frame 都帶著它：opcode 編碼為 `[op, seq, patch…]`（opcode 107 的 state 陣列相同），JSON 物件編碼為 `seq` 欄位。沒有 commit 的 plan 會留下空號。在 opcode 編碼中，序號讓每個 state frame 多出 1–9 bytes。
- **握手，以及相容性中斷。** 每個 hosted land 都要求 join 的 `stateUpdateFeatures` 帶 `syncSequence`，規則與 `pathIndex` 相同。沒有宣告它的 client（早於此變更的 SDK 或壓測 client）會在 join 時被拒。目前沒有關閉的方式，之後可以再加。
- **Ack。** client 以自己的訊息編碼送出 `[108, seq]`，即它最後套用的序號。SDK 每秒送一次（`ackIntervalMs`）；套用路徑在間隔已過時也送一次（背景分頁會節流計時器）；收到 firstSync 或 resync 後立即送一次。Ack 不是 transport message：router 直接交給 land 的 adapter，land 看不到它。每個 ack 都算存活訊號，值沒變的也算。
- **延遲（lag）** 是已 commit 給該 session、但它尚未 ack 的最舊 frame 的時間長度。
- **判斷**：由每個 sync plan 對其收件者判斷；關閉，以及沒有週期性 sync 的 land，則由 250 ms 的 timer 判斷：

| 條件（依此順序檢查） | 決定 |
|---|---|
| 最舊未 ack 的 frame 是完整畫面（firstSync 或 resync），且超過 `SYNC_ACK_TIMEOUT_MS`（10 s）未 ack，但 ack 仍持續送達 | 以 **4010**（slow consumer）關閉 |
| 有未 ack 的 frame，且超過 `SYNC_ACK_TIMEOUT_MS` 沒有任何 ack | 以 **4011**（unresponsive）關閉 |
| 最舊未 ack 的 frame 是完整畫面 | 不處理：完整畫面不受延遲規則限制 |
| 延遲超過 `SYNC_LAG_RESYNC_MS`（3 s），且 `SYNC_ACK_FRESHNESS_MS`（2 s）內沒有 ack | **暫停（pending）**：不再送 frame，事件丟棄，直到 ack 恢復 |
| 暫停中且 ack 再次送達，或延遲超過 `SYNC_LAG_RESYNC_MS` 而 ack 仍新鮮 | **就地重送**；若這會是 `SYNC_LAG_SLOW_CONSUMER_WINDOW_MS`（60 s）內第 `SYNC_LAG_SLOW_CONSUMER_COUNT`（3）次，則改以 4010 關閉 |

- **就地重送。** 由一個 sync plan 在既有連線上送出玩家的完整畫面，型別為 **resync**（opcode 3，或 `"type":"resync"`），client 以 firstSync 方式解碼。每個 client 都必須處理 opcode 3（state-update opcode 現在是 0–3）：忽略它的 client 會留著過時的畫面；對 `StateUpdateOpcode` 的 Swift `switch` 或對 opcode union 的 TS `switch` 都要加上這個新 case。使用合併 frame（opcode 107）時，session 先收到快照，再收到同一序號的合併 broadcast frame，後者可能帶有 broadcast key scope 的重設。Client 讀取該 frame 的 key 定義與事件，但跳過它的 state patch，因為快照已包含這些內容；SDK、ws-loadtest 與 CLI 都這樣處理，該序號的 ack 也會在快照套用之後才送出。Land 不會察覺：沒有 leave、沒有 join，玩家狀態維持不變。畫面是以玩家為單位，所以該玩家的每個 session 都會收到快照，但只有落後的那個 session 計次。該 plan 本身這一輪的事件會隨之送出，與其他收件者相同；只有 session 暫停期間消耗的事件會丟棄並計數。一次 resync 會讓下一個合併 broadcast frame 對 land 內所有 client 重設 broadcast key scope，與 rejoin 相同；同一 plan 內多次 resync 共用一次重設。錄製的 sync stream 會先記一個 clear，再記一個標為 rejoin 的 seed，與重連相同，讓 replay 驗證檢查新的畫面。
- **無法完整編碼的快照**（含有該編碼無法表示的值，例如 JSON 中的 NaN）不會送出：resync 會取代 client 的畫面，缺少某個 patch 的快照會讓 client 刪掉那個欄位。Session 維持原狀，下一個 plan 再試一次。連續 3 次快照失敗後，以 **4012**（unencodable view）關閉該 session；只要 session 不再需要 resync，次數就歸零：有一次 resync 成功送出，或它靠 ack 追上進度（延遲回到 `SYNC_LAG_RESYNC_MS` 以下）。
- **連空的都無法編碼的第一個畫面**（#357）。從未拿到畫面的 session（firstSync 失敗的 legacy join）會由每個完整週期重試，沒有 periodic sync 的 Land 會自行排定這些週期（每次失敗一個延遲的 follow-up）；連續 3 次失敗後（join 本身那次也算），同樣以 **4012** 關閉，不論該 Land 是否追蹤同步延遲。只掉了部分 patch 的第一個畫面仍會送出：client 把 firstSync 當成合併套用，被丟掉的欄位只會缺到它們下次變動為止。畫面送出後次數即結束。
- **關閉。** 4010、4011 與 4012 都會結束連線，client 不會自行 rejoin。SDK 透過 `onDisconnect` 回報 code；ws-loadtest 只有在 `--reconnect on-server-close` 時才會重新連線，與其他 server close 相同；ServerLoadTest 將關閉次數計入 `serverClosesByCode`。
- **關閉寬限**（#339）。4010、4011 或 4012 的 close frame 寫出後，server 會讓連線再開最多 `SYNC_LAG_CLOSE_GRACE_MS`（2 s）。這段期間它照常讀 socket（即使 inbound 處於暫停也照讀），讀到的內容全部丟棄；收到 client 的 close frame 或寬限到期時才關閉 channel。若在仍有未讀 inbound 資料時（落後的 client 在看到關閉前送出的 ack）立刻關閉，kernel 會送出 RST，可能讓 client 端丟掉 close frame，client 看到的就會是 1006 而不是該 code。close frame 的寫出仍受 close-frame timeout（5 s）限制。`SessionClose` 以 `closeGrace` 帶著寬限。server 關閉時發出的 1001 close 有 500 ms 寬限，關閉流程會在關閉 session 那一步內等它結束；其他 server close 沒有寬限。寬限期間讀到的內容一律不保留：每個 frame 受最大 frame 大小限制並直接丟棄，因此成本只是寬限時間內的讀取。`WebSocketTransport` 等待已關閉連線之 callback 的時間也會延長同樣長度（`serverCloseConfirmDeadline(for:)`，即 10 s 的確認逾時加上寬限），所以寬限再長，transport 也不會在 channel 仍開著時就遺忘該 session。
- **SDK** 會把 resync 與現有畫面調和：建出新狀態、與舊狀態比對，只通知淨變化：逐一觸發 `onPatch`，再觸發一次 `onStateUpdate`，接著是 map 訂閱（淨新增與移除），最後 `onResync`。未變動的子樹保留原物件，遊戲持有的參照仍會更新。
- **計數器**（adapter）：`syncLagResyncs`、`syncLagResyncsAlongside`、`syncLagPendingMarks`、`syncLagKeyScopeResets` 與 `syncLagKeyScopeResetBytes`（重設 frame 的位元組數乘上收件者數）、`syncLagDroppedEvents`、`syncLagSlowConsumerCloses`、`syncLagUnresponsiveCloses`、`syncLagDroppedAcks`、`syncLagSnapshotEncodeFailures`（未送出的快照）與 `syncLagUnencodableCloses`。Transport profile（`TRANSPORT_PROFILE_JSONL_PATH`）每個時間窗也帶有相同的計數，為各 land adapter 的加總：`syncLagResyncs`、`syncLagResyncsAlongside`（同一玩家另外收到快照的 session）、`syncLagPendingMarks`、`syncLagKeyScopeResets`、`syncLagKeyScopeResetBytes`、`syncLagDroppedEvents`、`syncLagSlowConsumerCloses`（4010）、`syncLagUnresponsiveCloses`（4011）、`syncLagDroppedAcks`、`syncLagSnapshotEncodeFailures` 與 `syncLagUnencodableCloses`（4012）。ws-loadtest 會回 ack，並計算每條連線收到的 resync 次數。ServerLoadTest 的 in-process client 每秒回一次 ack，並回報送出的 ack 數與 server 依 close code 分類的關閉次數（`totalSyncAcksSent`、`serverClosesByCode`）。
- **設定。** `NIOLandServerConfiguration.syncLag` 是一個 `SyncLagPolicy`，包含上列每個門檻。預設值為 `SyncLagPolicy.fromEnvironment()`，在程式中設定的值會取代它。只有 hosted land 會追蹤：透過 public initializer 建立的 `TransportAdapter` 或 `LandManager` 不送序號，也不追蹤。
- **關閉**是在同一個同步步驟裡、連同連線世代一起決定，因此絕不會關到之後重用同一 session ID 的新連線。

### 接收積壓上限

一個 session 的訊息依序交給 transport，每則都在前一則處理返回之後（每個 session 的接收鏈）。其中一則很慢時，後面的都要等，例如 join 正在查找 land。這段期間 server 仍持續讀取 socket，因此不斷送訊息的客戶端會讓訊息在記憶體中堆積。這個上限防止這種情況（#113）：
- **超過上限：** 已讀入但尚未交出的訊息超過 `WS_INBOUND_BACKLOG_MAX_MESSAGES` 則，或超過 `WS_INBOUND_BACKLOG_MAX_BYTES` 位元組時，server 停止讀取該 session 的 socket，由 TCP 流量控制讓客戶端放慢。不會關閉連線，也不會丟棄任何訊息。
- **恢復：** 兩者都降到各自上限的一半以下時恢復讀取。暫停前後訊息順序不變。

這是單一 session payload 積壓的軟性上限。跨過上限時已經讀入的部分仍會計入，也就是同一輪讀取解碼出的所有 frame：依這個 server 的 channel 設定，最多 16 次 socket 讀取、每次最多 64 KiB（共 1 MiB）。另外還有一則正在重組的訊息，最大到 server 的最大 frame 大小。decoder 的緩衝與每則訊息的額外開銷不在 payload 之內。上限以 session 為單位，這裡不限制所有 session 的總和。

暫停中的 session 不讀取任何 frame，包括客戶端的 close frame 與 keepalive pong。因此客戶端自己發起的關閉，要等恢復讀取後才會被看到。暫停期間送出的 keepalive ping 不會得到回應；暫停若在該 ping 之後再超過 `WS_PONG_TIMEOUT_MS`，session 會以 1001 關閉，與無回應的客戶端相同（`pongTimeoutCloses`）。ping 每 30 秒送一次，所以暫停最長約 50 秒才會被關閉。這是卡住的操作目前的上限。server 端發起的關閉在暫停期間照常作用，close frame 逾時與送出積壓上限也是。

join 在 in-turn 路徑被接受之後，它的 frame 會交給 land 的 adapter，由 adapter 保留到 join 完成，有自己的上限（256 個 frame 或 256 KiB，`JOIN_INBOUND_OVERFLOW`），這個上限會先觸發。接收積壓上限只在 router 處理某個 frame 本身被暫停時作用：接受之前，或 action dispatch 被慢速 resolver 卡住時。
