好，我幫你整理成一段「明顯是草案、但已經有結構」的設計備忘錄，之後你可以直接丟到 `DESIGN_DISTRIBUTED.md` 之類的文件裡慢慢長大。

---

# Distributed StateTree：初步想法、可能問題與後續方向（草案）

> 目標：在維持 StateTree 語意模型（State + Action + Resolver + SyncPolicy）的前提下，
> 讓整個系統可以橫向擴充、支援多伺服器、並盡可能保持 stateless API 的彈性。

---

## 一、核心初步想法（高層概要）

1. **邏輯上只有「一棵 StateTree」**

   * StateTree 仍然是 domain 的單一真實來源（Single Source of Truth）。
   * 只是實體上拆成幾個 segment，分布在：

     * 各 WS 節點的記憶體
     * Redis / DB
     * Cluster event log

2. **依 SyncPolicy 分段（Segmented Replication Model）**

   * **Broadcast Segment**（`@Sync(.broadcast)` 等）

     * 所有人看到應該一致的狀態（場景、房間、回合數、公開資訊）。
     * 透過 Action Log / pub-sub 在多節點之間同步。
   * **Private/Per-Player Segment**（`.perPlayerSlice()` 等）

     * 每個玩家自己的背包、手牌、個人設定。
     * 不做節點間即時同步，只存在：

       * 玩家當前所在節點的 StateTree view（記憶體）
       * Redis / DB（持久化與換節點時載入）

3. **多 WS 節點架構**

   * 多台伺服器只負責：

     * 接 WebSocket / HTTP 連線
     * 執行 Action
     * 把 diff 推給掛在本機的 client
   * Broadcast 部分：在所有節點保持同步 snapshot。
   * Private 部分：節點 local + Redis，玩家換節點時重新載入。

4. **Passive + Active 雙模式共存**

   * **Active StateTree**：房間型、長連線、持續維護 state 的 Land。
   * **Passive StateTree**：request/response 模式，

     * 每個請求臨時建立一棵 Tree → Resolver 填資料 → 執行 Action → 回傳結果 → 丟棄。
   * 兩種模式都可以用相同 Action / State 模型，差異在於 state 的生命週期。

5. **Action 必須 deterministic + Resolver sealed inputs**

   * 為了支援：

     * 重播 / 回放
     * 多節點 broadcast segment 一致性
   * 非決定性來源（時間、隨機數、外部 API 回應）在 Resolver 階段就封存進 event，
     不讓各節點各自「再 call 一次」。

---

## 二、架構切面：設計方向概述

### 1. Segment 定義與分布策略

* **Broadcast segment**

  * 儲存於各節點記憶體 + （必要時）持久化至 DB。
  * 變化透過 cluster bus（Kafka / Redis Stream / 自製 log）傳播。
* **Private / per-player segment**

  * Node-local in-memory + Redis/DB。
  * 不在 cluster 間同步，只在「玩家換節點 / reconnect」時載入。

### 2. 玩家換節點流程（簡化）

1. 新節點收到連線（LB 導過來）。
2. 使用已同步好的 broadcast snapshot 作為基底。
3. 從 Redis 載入該玩家的 private state。
4. 組合出完整 StateTree view。
5. 送 FirstSync + 後續 diff。

### 3. Action Scope 分級（避免爆掉 cluster）

* **Self-only Action**：

  * 只改 `state` 裡屬於呼叫者的部份（private segment）。
  * 不需要 cross-node broadcast。
* **Scoped / Group Action**：

  * 只影響同隊、同房、同 group 的 subset。
* **Global / Admin Action**：

  * 影響整個 broadcast segment（例如：老師按「開始下一回合」）。
  * 必須低頻＋有權限控制（Teacher/GM/Admin）。

> 設計方向：
> **80–90% Action 應該是 self-only / scoped。
> Global Action 保留給真正的全域行為。**

---

## 三、可能問題與風險點（之後要細化）

### 1. 分散式一致性與事件順序

* **事件順序（Ordering）**

  * cluster bus 是否保證 global order？
  * 同一房間 / Land 是否至少有 per-partition order？
* **重送與去重（Retry / Idempotency）**

  * 客戶端重送 Action 時，如何避免同一事件被套用兩次？
  * 是否需要全域唯一的 Action ID + 去重機制？
* **重播（Replay）**

  * 節點掛掉重啟，要如何從 log / snapshot 補回 broadcast segment 的 state？

### 2. Broadcast segment 壓力與 blast radius

* 任意一個「頻繁發生，而且會改 broadcast 的 Action」

  * 會變成 cluster 上最貴的操作：

    * 每個 node 都要更新
    * 每個 node 下的 client 都要收 diff
* 要建立明確設計準則：

  * 哪些 Action 可以是 global？
  * 頻率限制？
  * 有沒有 throttle / debounce 機制？

### 3. Private segment 的一致性與併發

* **單玩家多裝置 / 多節點同時在線？**

  * 如果允許，要不要加 version / optimistic lock？
  * Redis 寫入是否需要 compare-and-set？
* **寫入策略**

  * 每次 private 變更是否立即寫 Redis？
  * 還是採用：

    * in-memory 為主
    * 週期性 flush
    * 或 on-disconnect flush？
  * 這會影響掉線 / 換節點時的資料精度。

### 4. Resolver 與外部系統

* Resolver 呼叫外部系統（DB / HTTP）

  * 在 distributed 情境下，要避免：

    * 多節點重複呼叫相同外部 API
    * 或在 replay 時又去觸發外部 side-effect。
* 解法方向：

  * 把「影響 state 的輸入」封存並廣播（sealed inputs），
    replay 時只用封存的結果，不再呼叫外部服務。
  * 真正有 side-effect（寄信、扣款）由單一節點或專職 worker 處理。

### 5. 效能與資源使用

* **broadcast snapshot 大小**

  * 要避免 broadcast segment 膨脹成「整個世界所有資料」。
  * 應鼓勵把大量個人資料放到 private segment + Redis。
* **diff 計算成本**

  * 已有 SnapshotConvertible / dirty tracking 等優化，
    但在多節點環境會乘上節點數，要持續量測與壓測。
* **Redis / DB 負載**

  * Private segment 讀寫頻率與遷移策略會直接影響後端儲存壓力。

### 6. Schema / 版本演進

* 多節點部署時：

  * 有沒有可能同時存在 v1 / v2 server？
  * StateTree schema version（`@Since`）在 multi-node 環境下要怎麼控管 rollout？
* 方向：

  * 盡量讓所有節點使用相同版本的 StateTree schema，
  * 差異交由 Persistence 層處理舊 snapshot → 新 struct 的補齊。

---

## 四、後續研究與設計方向（TODO 大項）

1. **定義 Distributed Runtime v1 的正式規格**

   * bus / log 介面（Publisher / Subscriber abstraction）
   * broadcast segment 的 apply 流程（含 replay / catch-up）
   * private segment 的載入 / flush 協議。

2. **設計 Action Scope / 权限標記**

   * 在 DSL 層標記：

     * self-only / scoped / global
     * 以及 who-can-call（Player / GM / Teacher）。
   * 讓 runtime 可以根據 Action 類型決定是否寫入 cluster log、是否做 cross-node sync。

3. **玩家換節點的完整流程設計**

   * reconnect / 斷線重連
   * LB 把同一玩家導到不同節點時要走的 state 恢復流程
   * 以及錯誤情境（Redis 一時讀不到、版本不符）要怎麼退回。

4. **錯誤模型與恢復策略**

   * 單節點 crash
   * cluster bus 短暫不可用
   * Redis / DB 延遲或寫入失敗
   * 對應玩家體驗（暫停 sync？僅 local 回應？顯示 degraded mode？）。

5. **檢查清單（Checklist）**

   * 未來設計新 StateTree / Action 時可以快速檢查：

     * 這個欄位應該是 broadcast 還是 private？
     * 這個 Action 的 blast radius 是多少？
     * 是否必須 deterministic？
     * 是否需要 sealed resolver input？
     * 是否影響跨節點同步？

---

你之後可以直接把這一份存成：

* `DESIGN_DISTRIBUTED_STATETREE_NOTES.md` 或
* 在 `DESIGN_EVOLUTION.md` 裡開一節「Distributed StateTree（草案）」

未來每想到新的情境（例如「多裝置登入」、「region 分區」、「邊緣節點」），就往這份文件加小節就好。
