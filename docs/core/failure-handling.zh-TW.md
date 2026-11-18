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
| 以參考型別（class）作為同步狀態（#464） | 註冊時拒絕：`LandDefinition.validateForRegistration`，`LandRegistrationError.sync` 的 `.valueSemantics`（[同步](sync.zh-TW.md#註冊時拒絕的型別)） | 已符合 |
| 壓縮編碼（`messagepack`、`opcodeJsonArray`）下，沒有 `@Payload` 的 server event 或宣告的 action response 型別（#521） | 註冊時拒絕：`LandDefinition.validateForRegistration`（`NIOLandHost.swift:366`、`LandManager.swift:406`）；`json` 下以其 `Codable` 形式寫出 | 已符合 |
| 其他僅由型別就能決定的型別錯誤：不支援的 dictionary key 型別、在 broadcast 欄位下有 player-dependent 欄位的 node | 註冊時拒絕：`LandRegistrationError.sync` 的 `.unsupportedKey`、`.policyNesting`（#535）。只有之後的實例才有的值（預設為空的集合中的一般 struct 元素、預設實例沒有採用的 enum case）與手寫 `toSnapshotValue()` 背後的儲存內容，在同步時才發現，處理方式同「結束 land」第一列；直接建立的 keeper 則在初始化時執行同一個檢查 | 已符合 |
| existential 型別的同步欄位（`Any`、`any P`） | 宣告的型別寫出 `any`、`Any`、`AnyObject` 或 `P & Q` 時在編譯期拒絕，`AnyHashable` 與 `AnyCodable` 依名稱拒絕；在一般 struct 或 `@SnapshotConvertible` 型別中，以集合的元素、key 或 value，或 optional 包住的型別出現的 `Any`、`AnyObject`、`AnyHashable` 與 `AnyCodable`，在註冊時以 `.existentialField` 拒絕。抓不到的有：未加 `any` 的 protocol 名稱、指向 existential 的 typealias、一般 struct 自己宣告為 `Any` 或 `any P` 的 property（只能看到其預設值的型別），以及手寫的轉換；這類欄位在第一次轉換失敗時結束 land（#535） | 已符合 |

### 結束 land

| 路徑 | 目前 | 狀態 |
|---|---|---|
| 執行時 conversion 拋出錯誤的欄位 | land 以 `syncConversion` 結束，並指出該欄位；plan 不提交也不送出任何東西，其 session 以 4016 關閉（`SyncPhasePlan.noteExtractionDrops`）。加入者的 view、resync 的 view 與 seed 也一樣 | 已符合（#535 第 1、3、4、6 列） |
| 轉成相同字串的 dictionary key | conversion 拋出 `SyncError.collidingKeys`，land 依任何拋出錯誤的 conversion 處理而結束。只有函式庫自己的 conversion 會檢查：自訂 `toSnapshotValue()` 自行建立 `.object` 時，key 在函式庫看到之前就已合併，這仍屬該型別自己的約定 | 已符合（#535 D8） |
| 編碼無法承載的 patch（例如 JSON 中的非有限數） | 不論在哪種 frame，land 都以 `syncEncode` 結束：合併廣播 frame（`encodeMergedBroadcastFrameOrFail`）、per-player 或合併式 frame、row addressing 表格的 row（`planPerPlayerFrames`、`stateFrameEncodeFailure`）。不會去掉它重新編碼，失敗的 cycle 不送出任何東西 | 已符合（#535 第 8、9、10 列） |
| 路徑在 schema 之外的 patch | 同上一列，並計入 `unmappedPathPatches`（一次失敗計一次） | 已符合（#535 D6）。目前全為 `let` 的 `@SnapshotConvertible` struct 在 schema 中沒有其下的路徑（#566） |
| 拋出錯誤的同步 plan | 第一次拋出錯誤就結束 land，其 session 以 4016 關閉，不重試。in-turn sync：keeper 在同一個 turn 結束它（`applyInTurnSyncResult`）。legacy sync（未啟用 in-turn）：adapter 不再送出任何東西並提交失敗，keeper 在下一個 turn 套用（`submitLandFailure`）。加入者獨立的 firstSync plan 拋出錯誤時，同樣結束 land，不排 follow-up（第 16 列） | 已符合 |
| 單一玩家的狀態 frame 或 broadcast-only frame 完全無法編碼 | land 結束；失敗的 cycle 不送任何東西，其 session 以 4016 關閉（`planPerPlayerFrames`、`planBroadcastOnlySeparateFrames`） | 已符合（#535 第 10、12 列） |
| resync 或第一次 view 的完整 view 無法編碼 | 第一次失敗就結束 land，不重試；不再送出 4012（`planPerPlayerFrames`、`planFirstSync`） | 已符合（#535 第 11、13 列） |
| 編碼失敗的 server event | opcode 107：合併 body 失敗的 event 改以獨立 frame 送出；完全沒有進入任何 frame 的 event、event frame 無法 pack，或合併 state 與 event 的 frame 無法 pack，會結束 land（`enqueueEventSynchronously`、`appendEventFrames`、`encodeMergedBroadcastFrame`）。未使用 opcode 107：frame 無法編碼的 event 結束 land；目標目前沒有接收者的 event 不算遺失 | 已符合（#535 第 17 列） |
| 以可變方式存取 `@Sync` 欄位後才拋出錯誤的輸入 handler（action、client event、server input、`OnJoin`、`OnLeave`） | land 以 `handlerWrite` 結束，位置是 `.input` 階段與該輸入的 sequence；在 tickless land 上呼叫者收到錯誤（tick land 的呼叫者在收件時已收到 ACK），排在它後面的輸入收到 `landClosed`，tick handler 不執行，其 session 以 4016 關閉（`LandKeeper.applyInputs`、狀態的寫入標記 `_syncWriteMark()`）。看不到的情況下，該輸入仍單獨失敗，寫入照常同步，debug build 會發出警告：`@Internal` 儲存、手寫的 conformance、手動替換的底層 wrapper（`_x = Sync(...)`，其全新標記在總和中抵銷另一個欄位的寫入）、寫入 65,536 次以上且 16 位元標記回繞後總和恰好回到原值的 handler，以及標記總和恰好與原值相同的整個狀態替換；在含巢狀 node 的狀態上，handler 內明確呼叫 `clearDirty()` 會被當成寫入（[Runtime](runtime.zh-TW.md#input-與-turn)） | 已符合（#535 §3.7）；讓該輸入能單獨失敗所需的寫入復原由 #87 追蹤 |
| replay land 在壓縮編碼下重送錄製的 event，且使用需明確啟用的 `.projectedWithFallback` event policy（`GenericReplayLand.swift:21`；非預設） | `fatalError`，整個 process 停止（`MessagePackTransportMessageEncoder.swift:277`、`TransportMessageEncoder.swift:346`） | 目標：透過 land 的 registry 重送；無法解析的 event 結束 replay land，絕不是 process（#538、#521） |
| replay 無法載入或對應錄製的輸入 | 以警告略過該輸入，該 tick 在沒有它的情況下執行（`LandKeeper.swift:4126-4139`、`:4250-4256`） | 目標：驗證執行失敗，並附上 tick 與原因（#521；規則由 #535 追蹤） |

### 結束 session

| 路徑 | 目前 | 狀態 |
|---|---|---|
| outbound writer 因超過上限而丟棄 frame | 該 frame 指向的每個 session 都被結束，在 transport 能關閉 session 時也會斷線；client 重新加入後取得完整 view（`TransportAdapter+Outbound.swift:38-63`） | 已符合 |

### 拒絕輸入

| 路徑 | 目前 | 狀態 |
|---|---|---|
| payload 無法解碼的 action | 在 intake 拒絕；client 收到錯誤（`LandKeeper.swift:2721`、`TransportAdapter.swift:6079`） | 已符合 |
| payload 無法解碼的 client event | 直接丟棄，不回錯誤給 client（`LandDefinition.swift:276-277`），卻仍被記錄為已套用，因為記錄發生在 handler 執行之前（`LandKeeper.swift:3487-3498`） | 目標：比照 action 拒絕，且不記錄（#537） |

### land 因失敗結束時

| 路徑 | 目前 | 狀態 |
|---|---|---|
| OnLeave 與 destroy handler | 失敗的 land 在失敗的 turn 內清除玩家，不執行 OnLeave；destroy handler 與存檔執行時看得到 `LandDestructionCause.failed` 與 `LandKeeper.failure`（`LandKeeper.swift:4892`）。有 host 時，失敗的拆除透過 host（`NIOLandServer`）停止 land：router 轉送每個 session 的 leave，leave 找不到玩家，不執行 OnLeave，然後關閉該 session。管理端停止在失敗之前就關閉的 session，其 leave 與任何停止一樣照常執行 | 已符合（#535 PR 1 part B） |
| 重新評估的錄製 | 失敗只錄一次，錄在其 tick 的 frame 中，就在結束 land 的 turn 片段內（`ReevaluationTickFrame.landFailure`，錄製格式 3.4）。Replay 停在該 tick 並回報它（`RunResult.liveFailure`）；見 [Reevaluation](reevaluation.zh-TW.md#pass-序號與-land-失敗34) | 已符合 |

## Close code

- **4016 `landFailed`：** 因失敗而結束的 land 以此關閉其 session，不論是直接建立還是由 host 管理。有 host 時，失敗的拆除與管理端停止一樣停止 land（detach、每個 session 的 leave、關閉），而 close code 在每個 session 的關閉請求發出時才讀取：管理端停止進行中 land 失敗時，關閉請求在失敗之後發出的每個 session 都收到 4016。已關閉、或關閉請求在失敗之前就發出的 session 維持 4014；請求送往 transport 的最後一段途中才失敗的也一樣。host 關機流程一旦接手 session 自行關閉（`closeSessionsForShutdown`），之後才失敗的 land，其 session 以關機的 1001 關閉。
- **4012 `unencodableView`：** 保留不用，不再送出（#535）。在此之前，resync 或第一次 view 的 frame 持續無法編碼時會以它關閉 session；現在這類失敗以 4016 結束 land。
- **4014 `landStopped`：** 管理端停止一個沒有失敗的 land。

## 其他系統的做法

其他 server 採取相同的做法。以 room 為單位的 server 在 room 發生未處理的錯誤時會銷毀 room 並斷開其 client。有些引擎在單一連線發生溢位或序列化錯誤時只踢掉該連線，client 重新連線後取得完整狀態。deterministic lockstep 引擎在 checksum 不符時停止該 session。supervision tree 讓失敗的 process 結束（"let it crash"），而不是就地復原。

## 相關文件

- [同步規則](sync.zh-TW.md)
- [Runtime 運作機制](runtime.zh-TW.md)
- [Deterministic Re-evaluation](reevaluation.zh-TW.md)
