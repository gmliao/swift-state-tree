[English](failure-handling.md) | [中文版](failure-handling.zh-TW.md)

# 失敗處理

本頁說明 SwiftStateTree 如何處理同步、編碼、handler 與輸入中的失敗，並逐條列出程式碼目前相對於這條規則的狀態。有幾條路徑還沒照規則走；表格會標出是哪些，以及追蹤各項的 issue。

## 規則

判斷標準是：這個失敗能不能回到完全正確。

- **能：復原。** 能恢復正確狀態的路徑保留，例如送出完整 view 的 resync。
- **不能：結束被這個失敗弄壞的最小單位。** 記錄原因，然後結束該單位。

不要加入「吸收後繼續」的路徑。吸收會把 bug 藏起來：client 顯示錯誤的狀態，server 看起來卻一切正常，也沒有任何東西回報。

一個 process 承載許多 land，所以這個單位絕不會是 process。一個 land 的失敗不會讓另一個 land 停下。

## 範圍：結束什麼

範圍取決於失敗弄錯了什麼（#535 決定；見[決定紀錄](https://github.com/gmliao/swift-state-tree/issues/535#issuecomment-6852509570)與[計畫](https://github.com/gmliao/swift-state-tree/blob/440210de/Notes/plans/2026-11-13-sync-failure-ends-unit.md)）：

| 失敗 | 弄錯了什麼 | 結束什麼 |
|---|---|---|
| 註冊 land 時就能知道的型別錯誤 | 從第一次同步起的每個接收者 | 什麼都不執行：**拒絕註冊** |
| 弄壞每個接收者的 view 或 land 狀態的失敗，包括執行時才發現的型別錯誤 | 每個接收者，或狀態本身 | 關閉 **land**，並記錄錯誤 |
| 只影響單一連線的失敗，例如該連線的 outbound 佇列超過 writer 的上限 | 只有該連線的 frame | 關閉 **該 session**。重新加入會送出完整 view，狀態再次正確，所以 land 繼續執行 |
| client 送來的格式錯誤輸入 | 尚未弄錯任何東西 | 拒絕 **該輸入**，並告知 client。session 與 land 繼續執行 |

event 編碼失敗是值本身的問題，與接收者無關：每個 event 在分送給接收者之前只編碼一次。所以不論目標是誰，它都會結束 land（#521）。

目前沒有已知只限於單一玩家 view 的同步失敗。玩家的 view 是 land 狀態的確定性函數，重新加入會重算出同樣的失敗。所以每個同步失敗都結束 land，包括 resync 或第一次 view 的 frame（#535）。上表的 session 一列適用於真正只屬於單一連線的失敗，例如 outbound writer 的上限。結束 session 的失敗不能形成循環：重新加入後再次發生就結束 land。

## 程式碼目前的狀態

以 `main` 9755a625 為準；行號是該 commit 的行號。**已符合** 表示程式碼已經照規則做。**目標** 表示還沒有，由對應 issue 追蹤修改。

### 拒絕註冊

| 路徑 | 目前 | 狀態 |
|---|---|---|
| 以參考型別（class）作為 state（#464） | 編譯期拒絕：state 欄位的值是 `PlainData`（[同步](sync.zh-TW.md#同步狀態只能由-value-type-組成)）；藏在手寫的 `PlainData` witness 後面時，註冊時拒絕：`LandDefinition.validateForRegistration`，`LandRegistrationError.sync` 的 `.valueSemantics`（[同步](sync.zh-TW.md#註冊時拒絕的型別)） | 已符合 |
| 壓縮編碼（`messagepack`、`opcodeJsonArray`）下，沒有 `@Payload` 的 server event 或宣告的 action response 型別（#521） | 註冊時拒絕：`LandDefinition.validateForRegistration`（`NIOLandHost.swift:366`、`LandManager.swift:406`）；`json` 下以其 `Codable` 形式寫出 | 已符合 |
| 其他僅由型別就能決定的型別錯誤：不支援的 dictionary key 型別、在 broadcast 欄位下有 player-dependent 欄位的 node | 註冊時拒絕：`LandRegistrationError.sync` 的 `.unsupportedKey`、`.policyNesting`（#535）。只有之後的實例才有的值（預設為空的集合中的一般 struct 元素、預設實例沒有採用的 enum case）與手寫 `toSnapshotValue()` 背後的儲存內容，在同步時才發現，處理方式同「結束 land」第一列；直接建立的 keeper 則在初始化時執行同一個檢查 | 已符合 |
| existential 型別的 state 欄位（`Any`、`any P`） | 編譯期拒絕：state 欄位的值是 `PlainData`，existential 不是，指向它的 typealias 與未加 `any` 的 protocol 名稱也一樣；宣告的型別寫出 `any`、`Any`、`AnyObject` 或 `P & Q`，或 `AnyHashable`、`AnyCodable` 時，macro 會以自己的訊息指出（#535）。藏在手寫的 `PlainData` witness 後面時：以集合的元素、key 或 value，或 optional 包住的型別出現的 `Any`、`AnyObject`、`AnyHashable` 與 `AnyCodable`，在註冊時以 `.existentialField` 拒絕；宣告為 `Any` 或 `any P` 的 property 只能看到其預設值的型別，手寫的轉換不會被檢查；這類值在第一次轉換失敗時結束 land | 已符合 |
| 兩個不同的型別同名，例如 `A.Item` 與 `B.Item`（#602） | 在 state 中，註冊時拒絕：`LandRegistrationError.sync` `.typeNameCollision`；在 schema 的其他地方（payload，或同一份 schema 的兩個 land），產生 schema 時拒絕：`SchemaTypeNameCollisionError`；註冊會被 replay 紀錄的 land 時，紀錄的 schema fingerprint 會走訪整個 land（包括 server input 與 set 的元素），在那裡拒絕：`LandRegistrationError.typeNameCollisions`（[同步](sync.zh-TW.md#註冊時拒絕的型別)） | 已符合 |
| 同步 state 或 payload 中的 `Decimal`：event、action、其 response 或 server input（#597） | 編譯期拒絕：state 中不論怎麼寫（`Decimal` 不是 `PlainData`），payload 中則是宣告的型別寫出它時（`@Payload`）；typealias 讓語法看不到，或手寫的 `PlainData` witness 讓它進來時，註冊時拒絕：state 中以 `LandRegistrationError.sync` 的 `.decimalField`，其他地方以 `LandRegistrationError.decimalFields`，每個欄位一條路徑；其餘在第一次送出時，由 JSON 編碼與 MessagePack encoder 拒絕，land 以 `.eventEncode` 或 `.responseEncode` 結束（[同步](sync.zh-TW.md#註冊時拒絕的型別)） | 已符合 |
| 同一種 action、client event 或 server input 型別有兩個 handler，或兩種不同的輸入型別或已註冊 event 型別共用同一個 wire 名稱（#599） | 註冊時拒絕：`LandRegistrationError.duplicateHandlers`，指出該型別與兩處宣告的 `fileID:line`；未經註冊直接建立的 keeper 在初始化時拒絕（[Land DSL](land-dsl.zh-TW.md#每種型別一個-handler)） | 已符合（#586、#599） |
| 已註冊的 server event、client event 或 action 型別，其 wire 名稱（`_payloadWireName`）不是 schema 為它取的名稱：型別名稱的最後一段，去掉結尾的 `Event` 或 `Action`。改名後以手寫的 `_payloadWireName` 保留舊名稱，就屬於這種情況（#521 EV2） | 註冊時拒絕：`LandRegistrationError.wireNameMismatches`，指出種類、型別與兩個名稱；每個入口都檢查，包括 schema 產生與 replay。請保留型別名稱，或改名後重新產生 schema 與 client | 已符合（#521） |
| host 傳入 `eventHashes`，而某個已註冊的 server event 在其中沒有項目（#521 EV3、N8） | 註冊時拒絕：`LandRegistrationError.serverEventsWithoutHash`，指出該 event 與其型別；在 `NIOLandHost.register`（reevaluation 輔助函式會在 live land 註冊前先檢查其 replay 定義）與 `LandManager` 第一次建立時檢查。沒有 `eventHashes` 時不檢查，event 以名稱送出；使用 opcode JSON 或 MessagePack 訊息時，缺少項目的表也會讓該 event 以名稱送出，依該表建置的 client 無法對應。純 JSON 不使用這張表，但傳入的表仍會檢查。只檢查鍵：opcode 不同但完整的表會通過 | 已符合（#521） |
| 會錄製或為 reevaluation 註冊的 land，含有 record schema fingerprint 無法列出欄位的型別：有欄位但沒有 `@Payload` 的 payload 或 server input、無法建出 sample 的巢狀值、這種值的 `Set`，或兩個 `@Payload` 欄位共用一個 wire key | 註冊時拒絕：`LandRegistrationError.schemaFingerprint`，指出該型別（[Reevaluation](reevaluation.zh-TW.md#schema-fingerprint36)）。不錄製時照常註冊；直接建立的 keeper 不記錄 fingerprint、記錄一則警告，其錄製在 replay 時被拒絕 | 已符合（#521） |

### 結束 land

| 路徑 | 目前 | 狀態 |
|---|---|---|
| 執行時 conversion 拋出錯誤的欄位 | land 以 `syncConversion` 結束，並指出該欄位；plan 不提交也不送出任何東西，其 session 以 4016 關閉（`SyncPhasePlan.noteExtractionDrops`）。加入者的 view、resync 的 view 與 seed 也一樣 | 已符合（#535 第 1、3、4、6 列） |
| 轉成相同字串的 dictionary key | conversion 拋出 `SyncError.collidingKeys`，land 依任何拋出錯誤的 conversion 處理而結束。只有函式庫自己的 conversion 會檢查：自訂 `toSnapshotValue()` 自行建立 `.object` 時，key 在函式庫看到之前就已合併，這仍屬該型別自己的約定 | 已符合（#535 D8） |
| 編碼無法承載的 patch（例如 JSON 中的非有限數） | 不論在哪種 frame，land 都以 `syncEncode` 結束：合併廣播 frame（`encodeMergedBroadcastFrameOrFail`）、per-player 或合併式 frame、row addressing 表格的 row（`planPerPlayerFrames`、`stateFrameEncodeFailure`）。不會去掉它重新編碼，失敗的 cycle 不送出任何東西 | 已符合（#535 第 8、9、10 列） |
| 路徑在 schema 之外的 patch | 同上一列，並計入 `unmappedPathPatches`（一次失敗計一次） | 已符合（#535 D6）。目前全為 `let` 的 `@SnapshotConvertible` struct 在 schema 中沒有其下的路徑（#566） |
| 拋出錯誤的同步 plan | 第一次拋出錯誤就結束 land，其 session 以 4016 關閉，不重試。keeper 在同一個 turn 結束它（`applyInTurnSyncResult`）。Debug freeze 的 settle 也是 sync-only turn：其 plan 拋出錯誤時在該 turn 結束 land，freeze 則丟出該失敗。加入者獨立的 firstSync 不是 turn：其 plan 拋出錯誤時，會關閉 output gate 並提交失敗，keeper 將它當作 input 套用，結束 land，不排 follow-up（第 16 列） | 已符合 |
| 單一玩家的狀態 frame 完全無法編碼 | land 結束；失敗的 cycle 不送任何東西，其 session 以 4016 關閉（`planPerPlayerFrames`） | 已符合（#535 第 10、12 列） |
| resync 或第一次 view 的完整 view 無法編碼 | 第一次失敗就結束 land，不重試；不再送出 4012（`planPerPlayerFrames`、`planFirstSync`） | 已符合（#535 第 11、13 列） |
| 編碼失敗的 server event | opcode 107：合併 body 失敗的 event 改以獨立 frame 送出；完全沒有進入任何 frame 的 event、event frame 無法 pack，或合併 state 與 event 的 frame 無法 pack，會結束 land（`enqueueEventSynchronously`、`appendEventFrames`、`encodeMergedBroadcastFrame`）。未使用 opcode 107：frame 無法編碼的 event 結束 land；目標目前沒有接收者的 event 不算遺失 | 已符合（#535 第 17 列） |
| 壓縮編碼下的無型別 server event：payload 不是 payload 型別（dictionary、array、基本型別）的 `AnyServerEvent(type:payload:)`。land 程式碼沒有無型別的 emit（`emitAnyServerEvent` 已移除，#521），所以只有框架的 bug 會建出這種 event | encoder 拋出 `UntypedPayloadError`，event 沒有進入任何 frame，land 如上一列以 `eventEncode` 結束；其 session 以 4016 關閉，process 與其他 land 繼續執行。`json` 下 payload 照原樣寫出 | 已符合（#544）；無型別 emit 已移除（#521） |
| 壓縮編碼下不是 payload 型別的 action response：只有 package 層級的型別抹除 action handler 能產生這種值（所有 `HandleAction` 形式與 `AnyActionHandler` 的公開 init 都回傳 action 宣告的 `Response`，#561、#586） | encoder 拋出 `UntypedPayloadError`；client 會收不到回覆，因此 land 以 `responseEncode`（stage `actionResponse`）結束，其 session 以 4016 關閉。該 action 的寫入保留。output gate 在失敗的那個 segment 內關閉；process 與其他 land 繼續執行。`json` 下回應照原樣寫出。走到編碼這一步的 response，會在檢查其請求是否仍有效之前就先編碼，因此過期請求的 response 無法編碼時，land 一樣會結束：問題出在型別，下一個仍有效、同型別的 response 也會以同樣方式失敗。尚未完成的 response 若在完成時其請求已過期，會在編碼之前就被丟棄 | 已符合（#544） |
| action 的錯誤回覆無法編碼（handler 或 `validate` 拒絕該 action 時送出的回覆） | 同上一列：client 會收不到回覆，因此 land 以 `responseEncode`（stage `actionResponse`）結束，其 session 以 4016 關閉，而不是只記錄失敗。output gate 在失敗的那個 segment 內關閉。與 response 相同，走到編碼這一步的錯誤回覆無法編碼時，即使請求已過期，land 一樣會結束 | 已符合（#691） |
| 手寫的 `_PayloadWireLeaf` 在 `messagepack` 下由 `_writeWire(into:)` 寫出格式錯誤的值：物件外的 key、沒有 key 的值、一個值配兩個 key、同一物件中重複的 key、第二個值、負的 count，或項目少於 count 的物件 | positional writer 拋出 `EncodingError`，指出第一個格式錯誤的呼叫，而不是讓 process trap；該 payload 無法編碼，land 依上面各列 payload 無法編碼的情況結束 | 已符合（#690） |
| 伺服器建出的 MessagePack frame 巢狀超過 64 層（array 與 map，frame 本身的層數也算）：state、event 或 response | packer 拒絕它，就像伺服器的 unpacker 會拒絕它一樣（`PayloadNesting.serverFrameMaxDepth`）。因此 land 會像任何無法編碼的 frame 一樣結束：state 是 `syncEncode`（在帶有該 state 的第一次 sync），event 是 `eventEncode`，response 是 `responseEncode`。使用 opcode 107 且有待送的 broadcast event 時，state 會放進合併的 frame `[107, state, events]`，比它自己的 frame 多一層：自己的 frame 就無法打包的 state 仍以 `syncEncode` 結束 land；單獨能打包、合併後不能的 state（自己的 frame 剛好 64 層）則在第一個 broadcast event 時以 `eventEncode` 結束 land，detail 會註明 state frame 單獨可以打包。payload 欄位可用的層數比 frame 少 2 到 4 層：合併的 opcode 107 frame 少 4 層，event 自己的 frame 少 2 層。typed leaf（`_PayloadWireLeaf`）寫出巢狀超過 64 層的 object 時，在寫入當下就會被拒絕。這是 MessagePack 的上限：JSON 編碼沒有上限（#715）。`pack(_:)` 超過上限也會丟錯。限制：巢狀到足以超過 64 層的 state node，可能在伺服器建立 snapshot 時就耗盡 stack，來不及讓 packer 拒絕該 frame，於是 process 直接停止，而不是 land 結束（在 macOS 的 debug build 實測約 28 層巢狀 node，每層 2 個 container；實際層數取決於 build 與 stack 大小；#716） | 已符合（#697） |
| replay land 重送錄製的 event（需明確啟用的 `.projectedWithFallback` event policy，或 replay 自己產生的 event） | runner 在每個 tick 排入佇列前先解析：每個錄製的 event 依名稱在 base land 的 registry 查找，並用錄製檔自己的 codec 解碼，replay land 再以有型別的方式送出（`emitEvent`），在錄製檔的值域內與 live event 位元組相同（`Date` 只保留到整秒；JSON 檢視中 `-0.0` 讀回為 `+0.0`）。錄製的 event 名稱未註冊，或 payload 無法解碼時，replay run 失敗：admin 狀態顯示該 tick、event 與錯誤，replay land 保持運作，之後不再顯示任何內容。讀取錄製檔失敗、state snapshot 無法編碼、或無法從 snapshot 重建 state 時也一樣；供給 replay land 的 run 遇到 land 無法顯示的結果時也一樣：沒有 frame（`unresolvedResult`）、其他 state 型別（`stateTypeMismatch`）、或沒有 state（`stateUnavailable`，例如無法計算 state hash 的 tick）。只用 `makeLand` 建立的 land 讀到這種結果時會讓 run 失敗 | 已符合（#521、#538） |
| replay 無法載入或對應錄製的輸入 | 以警告略過該輸入，該 tick 在沒有它的情況下執行（`LandKeeper.swift:4126-4139`、`:4250-4256`） | 目標：驗證執行失敗，並附上 tick 與原因（#521；規則由 #535 追蹤） |
| 拋出錯誤的 `OnInitialize` `validate` | 初始化失敗，和 OnInitialize resolver 以 `.failLand` 拋出錯誤時相同：什麼都不寫入也不記錄，land 被拆除且不執行 destroy handler，等待初始化的呼叫收到 `LandInitializationError`，等待中的 join 收到可重試的 `JOIN_DENIED`。重播時記錄表示 live 的 `validate` 已通過，因此重播的 `validate` 若拋出錯誤，initialize 檢查失敗（[Reevaluation](reevaluation.zh-TW.md#replay-中的-oninitialize)） | 已符合（#593） |
| transport 在 turn 執行中同步回呼 keeper（keeper 呼叫 transport 期間的回呼，到達 `submitSyncStream` 或 `syncTurnNow`） | keeper 拒絕這次呼叫，不做任何變更：它記下失敗、在這次呼叫中關閉 output gate，並在 turn 讀取 transport 的回答之前，以 `keeperReentry`（stage `syncPhase`）結束 land；turn 回報 `.landFailed`，其 session 以 4016 關閉。若 land 已在 drain，land 保留原本的 drain 原因，gate 一樣會關閉。turn body 執行時持有 keeper 的 state，回呼若在此時改動它，可能留下寫到一半的狀態 | live land 的每個 turn 都已符合，包括初始化（#700 K1b-5a） |

### 結束 session

| 路徑 | 目前 | 狀態 |
|---|---|---|
| outbound writer 因超過上限而丟棄 frame | 該 frame 指向的每個 session 都被結束，在 transport 能關閉 session 時也會斷線；client 重新加入後取得完整 view（`TransportAdapter+Outbound.swift:38-63`） | 已符合 |

### 拒絕輸入

| 路徑 | 目前 | 狀態 |
|---|---|---|
| payload 無法解碼的 action | 在 intake 拒絕；client 收到錯誤（`LandKeeper.swift:2721`、`TransportAdapter.swift:6079`） | 已符合 |
| 任何編碼中巢狀超過 32 層的 frame（陣列與物件，或 MessagePack 的 array 與 map） | 在解析之前就被拒絕，處理方式與無法解碼的 frame 相同：join 之前計入該 session 的拒絕 frame 額度（`HANDSHAKE_REFUSED_FRAME_BUDGET`），join 之後 client 收到解碼錯誤。巢狀這麼深的已錄製 action 在重播時以錯誤失敗，而不是耗盡 stack。更深的資料會在解碼鏈中耗盡 Darwin cooperative pool 執行緒的 544 KiB stack；範例 land 送出的 frame 最深為 7 層（#362）。#362 之前，JSON frame 最多接受 512 層，MessagePack frame 最多 64 層。client 的 JSON 必須是 UTF-8：UTF-16 或 UTF-32 的 frame，或含有 NUL byte 的 frame，以同樣方式拒絕 | 已符合（#362） |
| 寫入狀態後才拋出錯誤的 input handler | 不會發生：`HandleAction`、`HandleEvent`、`HandleServerInput`、`OnJoin` 與 `OnLeave` 的 body 都不會拋出錯誤，因此沒有輸入會留下部分寫入（#87）。輸入以其 `validate` 拋出錯誤來拒絕，此時什麼都還沒寫入；它單獨失敗，之後的輸入繼續，並被記錄為 rejected（[Runtime](runtime.zh-TW.md#input-與-turn)）。Lifecycle handler 寫入後同樣不會拋出錯誤：`OnFinalize` 與 `OnDestroyWhenEmpty` 接受不會拋出錯誤的 body，`OnInitialize` 接受這樣的 body，或一個 `validate` 與一個 `apply` | 已符合（#586、#593） |
| `CanJoin` 允許、但在 `OnJoin` 套用時已不適合的 join | `OnJoin` 無法拒絕它：`CanJoin` 在 join intake 時決定，`OnJoin` 在之後的 turn 才套用，因此 `CanJoin` 對其他輸入會改變的狀態所做的檢查可能已過時。玩家照常加入，由 `OnJoin` 處理不適合的 joiner（讓他成為旁觀者，或發出 event 請他離開）；見 [Land DSL](land-dsl.zh-TW.md#join-檢查)。`MaxPlayers` 不受影響：它在插入玩家時檢查，並計入等待中的 joiner | 目標：turn 內的 join 檢查（#588） |
| payload 無法解碼的 client event | 在接收時拒絕，不進佇列也不記錄；client 收到 `EVENT_INVALID_PAYLOAD`（`LandKeeper.swift:2992`、`TransportAdapter.swift:2610`）。重播的則仍由其 handler 丟棄，直到重播改為事先解碼整批輸入（#521） | 已符合（#537） |

### land 因失敗結束時

| 路徑 | 目前 | 狀態 |
|---|---|---|
| OnLeave 與 destroy handler | 失敗的 land 在失敗的 turn 內清除玩家，不執行 OnLeave；destroy handler 與存檔執行時看得到 `LandDestructionCause.failed` 與 `LandKeeper.failure`（`LandKeeper.swift:4892`）。有 host 時，失敗的拆除透過 host（`NIOLandServer`）停止 land：router 轉送每個 session 的 leave，leave 找不到玩家，不執行 OnLeave，然後關閉該 session。管理端停止在失敗之前就關閉的 session，其 leave 與任何停止一樣照常執行 | 已符合（#535 PR 1 part B） |
| 重新評估的錄製 | 失敗只錄一次，錄在其 tick 的 frame 中，就在結束 land 的 turn 片段內（`ReevaluationTickFrame.landFailure`，錄製格式 3.4）。Replay 停在該 tick 並回報它（`RunResult.liveFailure`）；見 [Reevaluation](reevaluation.zh-TW.md#pass-序號與-land-失敗34) | 已符合 |
| 失敗之後送出什麼 | land 的 output gate 關閉後，該 land 不再有任何 frame 進入佇列：沒有 state 或 event frame，沒有 action 的 response 或錯誤回覆，沒有 join response 或 join 錯誤，也沒有經由該 land 的 adapter 送出的 router frame。被丟棄的 frame 會計數（`framesDroppedLandFailed`）。有兩種 frame 仍會送出：session 帶著關閉的最後一個 frame（admission 之前結束的 join、join 之後 inbound 超量、router 的 join 失敗），以及每個 session 的 4016 關閉 | 已符合（#696） |
| 在 turn 之外發現的失敗 | action 的回覆或 `sendEvent` 的 event 編碼失敗，或 joiner 的第一次 sync 失敗，是 adapter 在 keeper 的 turn 之外發現的。adapter 在同一個 segment 內關閉 output gate，並把失敗記在 keeper 上。keeper 的下一個 step 在該 step 送出任何東西之前，就以這個失敗結束 land：tick turn 或 input turn 在套用 input 之後結束，sync-only turn 在其 phase 之前結束。因此等待中的 join 不會 flip，sync plan 不會執行，記下的失敗仍是第一個原因。沒有 step 待執行時，由 adapter 的提交結束 land | 已符合（#704） |
| 結束 land 的 turn 的呼叫者 | 結束 land 的 turn 不送出任何東西，回覆也不送，所以它消耗的每個 input 的呼叫者都得到 `LandInputRejection.landClosed`，handler 已回傳 response 的呼叫者也一樣。這適用於 turn 的 input 中有失敗項目、在 turn 之外記下的失敗，以及失敗的 sync phase。在 tick land 上，action 在提交時就已確認，這個確認保留。錄製把這些 input 記為已套用；錄下的 input 沒有結果，所以重播沒有結果可比對 | 已符合（#704） |

## Close code

- **4016 `landFailed`：** 因失敗而結束的 land 以此關閉其 session，不論是直接建立還是由 host 管理。有 host 時，失敗的拆除與管理端停止一樣停止 land（detach、每個 session 的 leave、關閉），而 close code 在每個 session 的關閉請求發出時才讀取：管理端停止進行中 land 失敗時，關閉請求在失敗之後發出的每個 session 都收到 4016。已關閉、或關閉請求在失敗之前就發出的 session 維持 4014；請求送往 transport 的最後一段途中才失敗的也一樣。host 關機流程一旦接手 session 自行關閉（`closeSessionsForShutdown`），之後才失敗的 land，其 session 以關機的 1001 關閉。
- **4012 `unencodableView`：** 保留不用，不再送出（#535）。在此之前，resync 或第一次 view 的 frame 持續無法編碼時會以它關閉 session；現在這類失敗以 4016 結束 land。
- **4017 `superseded`：** 同一個玩家的較新 join 取代了這個 session（每個玩家一個 session，最新者勝，#92 與 #531）。只有這條連線被關閉，reason 為 "logged in elsewhere"，close grace 為 500 ms；玩家與 land 在較新的 session 中繼續。client 不應在此 code 上重連：同一玩家的兩個 client 會互相取代而形成迴圈（#861）。#861 之前這個關閉只是普通的 1000。join 在兩種情況下以 `JoinError.superseded` 失敗（#860）。若它在 OnJoin resolver 執行期間被取代或離開，它的 OnJoin input 與移除它的那次 leave 的 OnLeave 都會被丟棄，但它的 OnJoin resolver 已經執行過（resolver 的副作用見 [Resolvers](resolver.zh-TW.md)）。若它在踢掉該玩家舊 session 的期間，同一玩家有更晚的 join 抵達，kick 返回時它會被 fence 掉：它不插入任何東西、不執行任何 OnJoin resolver，由最後抵達的 join 保有該玩家。經由 router 時，session 會先收到作為最後一個 frame 的 `JOIN_DENIED`，再收到這個 4017 關閉。
- **4014 `landStopped`：** 管理端停止一個沒有失敗的 land。

## 其他系統的做法

其他 server 採取相同的做法。以 room 為單位的 server 在 room 發生未處理的錯誤時會銷毀 room 並斷開其 client。有些引擎在單一連線發生溢位或序列化錯誤時只踢掉該連線，client 重新連線後取得完整狀態。deterministic lockstep 引擎在 checksum 不符時停止該 session。supervision tree 讓失敗的 process 結束（"let it crash"），而不是就地復原。

## 相關文件

- [同步規則](sync.zh-TW.md)
- [Runtime 運作機制](runtime.zh-TW.md)
- [Deterministic Re-evaluation](reevaluation.zh-TW.md)
