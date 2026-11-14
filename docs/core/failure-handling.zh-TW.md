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
| 以參考型別（class）作為同步狀態（#464） | 註冊時拒絕：`SyncValueSemantics.validate`（`LandTypeRegistry.swift:38`、`NIOLandHost.swift:363`、`SchemaExtractor.swift:20`） | 已符合 |
| 壓縮編碼（`messagepack`、`opcodeJsonArray`）下，沒有 `@Payload` 的 server event 或宣告的 action response 型別（#521） | 註冊時拒絕：`LandDefinition.validateForRegistration`（`NIOLandHost.swift:366`、`LandManager.swift:406`）；`json` 下以其 `Codable` 形式寫出 | 已符合 |
| 其他僅由型別就能決定的型別錯誤：不支援的值或 dictionary key 型別、在 broadcast 欄位下有 player-dependent 欄位的 node | 同步時才發現；處理方式同「結束 land」第一列 | 目標：註冊時拒絕（#535） |
| existential 型別的同步欄位（`Any`、`any P`） | 允許；無法轉換的值在同步時才發現，處理方式同「結束 land」第一列 | 目標：宣告的型別寫出 `any` 或 `Any` 時在編譯期拒絕，`AnyHashable` 與 `AnyCodable` 依名稱拒絕。未加 `any` 的 protocol 名稱、指向 existential 的 typealias，以及手寫的 conformance 在編譯期抓不到：這類欄位在第一次轉換失敗時結束 land（#535） |

### 結束 land

| 路徑 | 目前 | 狀態 |
|---|---|---|
| 執行時 conversion 拋出錯誤的欄位 | 該次同步捨棄這個欄位（client 保留舊值），計數並記錄，frame 的其餘部分照常送出（`SyncEngine.swift:1405-1428`、`TransportAdapter.swift:4190`） | 目標：關閉 land（#535） |
| 轉成相同字串的 dictionary key | 後一筆默默覆蓋前一筆（`SnapshotValue.swift:424`） | 目標：關閉 land（#535） |
| 編碼無法承載的 patch（例如 JSON 中的非有限數） | 在 opcode 107 合併廣播 frame 中：land 結束，其 session 以 4016 關閉（`encodeMergedBroadcastFrameOrFail`）。在 per-player 或合併式 frame 中：去掉該 patch 重新編碼後送出；該欄位在 client 上維持過期，直到它再次改變（`encodeDroppingUnencodablePatches`） | 合併廣播 frame 已符合；per-player 與合併式 frame 的目標：關閉 land（#535 PR 2） |
| 路徑在 schema 之外的 patch | 同上一列，並計入 `unmappedPathPatches`（一次失敗計一次） | 同上一列（#535 D6）。目前全為 `let` 的 `@SnapshotConvertible` struct 在 schema 中沒有其下的路徑（#566） |
| 拋出錯誤的同步 plan | 第一次拋出錯誤就結束 land，其 session 以 4016 關閉，不重試。in-turn sync：keeper 在同一個 turn 結束它（`applyInTurnSyncResult`）。legacy sync（未啟用 in-turn）：adapter 不再送出任何東西並提交失敗，keeper 在下一個 turn 套用（`submitLandFailure`）。加入者獨立的 firstSync plan 拋出錯誤時，在 #535 PR 2（第 16 列）之前仍會排一次 follow-up | 已符合 |
| 單一玩家的狀態 frame 或 broadcast-only frame 完全無法編碼 | land 結束；失敗的 cycle 不送任何東西，其 session 以 4016 關閉（`planPerPlayerFrames`、`planBroadcastOnlySeparateFrames`） | 已符合（#535 第 10、12 列） |
| resync 或第一次 view 的完整 view 無法編碼 | 重試；超過上限後以 4012 `unencodableView` 關閉 session（`commitFirstViewEncodeFailures`） | 目標：第一次失敗就關閉 land，不重試；不再送出 4012（#535 PR 2） |
| 編碼失敗的 server event | opcode 107：合併 body 失敗的 event 改以獨立 frame 送出；完全沒有進入任何 frame 的 event，或 event frame 無法 pack，會結束 land（`enqueueEventSynchronously`、`appendEventFrames`）。未使用 opcode 107：記錄錯誤，event 不送出 | opcode 107 已符合（#535 第 17 列）；未使用時的目標：關閉 land（#521） |
| 寫入狀態後才拋出錯誤的 handler | 該輸入單獨失敗，之後的輸入繼續；它的寫入保留並同步出去，debug build 會發出警告（`LandKeeper.swift:3836-3837`、`:3189`） | 目標：關閉 land（#535）；部分寫入由 #87 追蹤 |
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
| OnLeave 與 destroy handler | 失敗的 land 在失敗的 turn 內清除玩家，不執行 OnLeave；destroy handler 與存檔執行時看得到 `LandDestructionCause.failed` 與 `LandKeeper.failure`（`LandKeeper.swift:4892`）。host 停止時若在失敗的拆除之前先關閉某個 session，該 session 的 leave 仍會執行（`LandKeeper.swift:2397-2439`） | 失敗本身的拆除已符合；目標：host 的停止路徑在失敗的 land 上同樣略過 OnLeave（#535 PR 1 part B） |

## Close code

- **4016 `landFailed`：** 因失敗而結束的 land 以此關閉其 session（in-turn sync plan 拋出錯誤時已符合；其他列為目標，#535）。在 #535 PR 1 part B 之前，host 停止時先關閉的 session 收到的是 4014。
- **4012 `unencodableView`：** 目前在 resync 或第一次 view 的 frame 持續無法編碼時送出。#535 落地後保留不用，不再送出。
- **4014 `landStopped`：** 管理端停止，不變。

## 其他系統的做法

其他 server 採取相同的做法。以 room 為單位的 server 在 room 發生未處理的錯誤時會銷毀 room 並斷開其 client。有些引擎在單一連線發生溢位或序列化錯誤時只踢掉該連線，client 重新連線後取得完整狀態。deterministic lockstep 引擎在 checksum 不符時停止該 session。supervision tree 讓失敗的 process 結束（"let it crash"），而不是就地復原。

## 相關文件

- [同步規則](sync.zh-TW.md)
- [Runtime 運作機制](runtime.zh-TW.md)
- [Deterministic Re-evaluation](reevaluation.zh-TW.md)
