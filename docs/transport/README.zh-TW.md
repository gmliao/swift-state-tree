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

狀態更新在每個 sync 週期內以串行方式編碼。同一房間內每位玩家的更新依序編碼；多房間場景下，每個 `TransportAdapter` 獨立管理一個房間。

## 環境變數

Transport 相關行為可透過環境變數調整。所有變數在 `TransportAdapter` 初始化時讀取。完整清單與解析規則見 `TransportEnvConfig`（SwiftStateTreeTransport 模組）。

| 變數 | 型別 | 預設 | 說明 |
|------|------|------|------|
| `ENABLE_DIRTY_TRACKING` | Bool | init 參數 | 啟用 dirty-field 追蹤以產生較小 diff；高更新比例場景可關閉 |
| `USE_SNAPSHOT_FOR_SYNC` | Bool | true | 使用單次 snapshot 擷取；設為 `false` 使用舊版 broadcast + per-player 路徑 |
| `SYNC_STRATEGY` | String | `delta` | `delta` 只送變更欄位；`full-snapshot` 每次同步送每個接收者的完整視圖（量測用基線，非正式模式） |
| `ENABLE_CHANGE_OBJECT_METRICS` | Bool | false | 記錄每次 sync 的 changed vs unchanged 物件比例 |
| `CHANGE_OBJECT_METRICS_LOG_EVERY` | Int | 10 | 變更物件 metrics 日誌的 sync 週期間隔 |
| `CHANGE_OBJECT_METRICS_EMA_ALPHA` | Double | 0.2 | 變更率 EMA alpha（0.01–1.0） |
| `AUTO_DIRTY_TRACKING` | Bool | true | 依變更率遲滯曲線自動切換 dirty tracking |
| `AUTO_DIRTY_OFF_THRESHOLD` | Double | 0.55 | 關閉 dirty tracking 的 EMA 門檻 |
| `AUTO_DIRTY_ON_THRESHOLD` | Double | 0.30 | 開啟 dirty tracking 的 EMA 門檻 |
| `AUTO_DIRTY_REQUIRED_SAMPLES` | Int | 30 | 模式切換前需連續採樣次數 |
| `TRANSPORT_PROFILE_JSONL_PATH` | String | 關閉 | 設定後啟用 transport profiling，將 JSONL 寫入此路徑 |
| `TRANSPORT_PROFILE_INTERVAL_MS` | Int | 1000 | Profiling 寫入間隔 (ms)，最小 100 |
| `TRANSPORT_PROFILE_SAMPLE_RATE` | Double | 0.01 | Latency 採樣率 (0.001–1.0) |
| `TRANSPORT_PROFILE_MAX_SAMPLES_PER_INTERVAL` | Int | 500 | 每間隔最大 latency 採樣數 (10–10000) |
| `OUTBOUND_WRITER_MAX_BYTES` | Int | 67108864 (64 MiB) | 每個 land 的 outbound writer 排隊位元組上限（最小 1024）。超過上限的 frame 會被丟棄，受影響的 session 會被斷線 |

由其他地方讀取：

- `DYNAMIC_KEY_COMPRESSION`（Bool，預設 true）：使用 path hash 的 opcode state update 在 dynamic key 第一次使用後改送 table slot（true），或一律送完整字串（false）。只有以 `TransportEncodingConfig.dynamicKeyCompressionFromEnvironment()` 建立 encoding 設定的 server 會讀取（Demo 與 Game server 皆有）。
- `WS_PONG_TIMEOUT_MS`（Int，預設 20000；NIO hosting，`NIOWebSocketServerConfiguration.pongTimeout`）：server 每 30 秒 ping 每個 WebSocket session 一次，各 session 有自己的相位。ping 之後這麼多毫秒內若沒收到對端任何 frame（pong 或任何訊息都算），server 以 1001（going away）關閉連線。計時從 ping 寫入 channel 起算，所以排在慢速讀取端積壓之後的 ping 也會計入。須為正數且小於 30000；其他值使用預設值。
- `IN_TURN_SYNC` 與 `LAND_LOOP_PHASE_OFFSET`（runtime，預設開啟）：見 [Runtime](../core/runtime.zh-TW.md#in-turn-sync預設)。

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

每行也有 `pongTimeoutCloses`：keepalive ping 之後 `WS_PONG_TIMEOUT_MS` 內沒收到任何 frame 而被關閉的 WebSocket session 數（NIO hosting）。

送出積壓（NIO hosting，#61）：只量測，不設上限也不丟棄。
- `sendBufferedBytesMax`：每個視窗內，任一 session 的 channel 在不可寫期間緩衝的最大位元組數（NIO 的 `bufferedWritableBytes`，已寫出但 socket 尚未接收）。只在超過寫入高水位（預設 64 KiB）時取樣：channel 轉為不可寫時取一次，之後仍不可寫期間每次寫入再取；0 表示沒有任何 channel 超過高水位。
- `sendUnwritableEpisodes`：視窗內 channel 超過寫入高水位的 session 次數。
- `sendUnwritableLongestMs`：這些時段中，在視窗內結束的最長一段。
- `sendUnwritableSessions`：gauge，不會每個視窗歸零：寫出該行時處於不可寫的 session 數。這是每個視窗結束時的取樣，不是峰值：在同一個視窗內轉為不可寫又恢復的 session，只會反映在 `sendUnwritableEpisodes`。

ws-loadtest 會按階段在 "Server send backlog" 段落列出。
