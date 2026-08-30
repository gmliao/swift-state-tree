# 相關系統對照：以 StateTree programming model 的語言重新描述

> **文件性質**：工作筆記，供改稿用，不是 docs/ 的正式文件。
> **目的**：把幾個最接近的系統用 StateTree model 的術語重新描述一遍，檢驗 (1) 模型是否足以描述它們、(2) SST 所佔的設計點是否真的是空的。
> **建立日期**：2026-08-29
> **查證狀態**：標 ✅ 的欄位已對照官方文件（2026-08-29 抓取）；標 ⚠️ 的是憑既有知識填寫，寫進論文前必須再查。

---

## 0. 模型詞彙（對應論文草稿 §3.1.2）

| 符號 | 意義 | SST 對應物 |
|---|---|---|
| $S_t$ | 權威狀態快照 | StateTree（`@StateNodeBuilder` struct） |
| $A_t$ | 觸發轉換的輸入（client action、tick、lifecycle） | `ActionPayload`、`Tick`、`OnJoin/OnLeave` |
| $E_t$ | 外部環境／非決定性來源（DB、時間、亂數、I/O） | Resolver 存取的 service |
| $\rho$ | 脈絡生成：$C_t = \rho(S_t, A_t, E_t)$，**在 $\delta$ 之前**執行 | `ContextResolver`（並行、eager） |
| $C_t$ | 脈絡（resolver 輸出），**不進 $S$、不同步、但被記錄** | `ResolverOutput` |
| $\delta$ | 決定性轉換：$S_{t+1} = \delta(S_t, A_t, C_t)$ | Action handler（同步、actor 內） |
| $\pi_k$ | 對讀者 $k$ 的投影／過濾：$V^k_t = \pi_k(S_t)$ | `@Sync(.broadcast / .perPlayer / .serverOnly …)` |
| Replay | $S^{replay}_{t+1} = \delta(S^{replay}_t, A^{rec}_t, C^{rec}_t)$，跳過 $\rho$ | Reevaluation mode + state hash 驗證 |

模型的四條限制（草稿 §3.1.4）：**(L1)** 單一權威 $S$；**(L2)** 只能經 $\delta$ 改 $S$；**(L3)** 非決定性隔離於 $C$ 且可記錄；**(L4)** $\pi$ 與 $\delta$ 分離、宣告式。

---

## 1. 逐系統描述

### 1.1 SpacetimeDB（Clockwork Labs）

**官方模型**：Tables + Reducers + Procedures + Views + Subscriptions，module 編成 WASM 跑在資料庫內。

| 模型元素 | SpacetimeDB 的對應 | 查證 |
|---|---|---|
| $S_t$ | 關聯式 tables（private 預設，public 才可被 client 讀） | ✅ |
| $A_t$ | reducer 呼叫（client 觸發）、scheduled reducer（tick） | ✅ / ⚠️ scheduled reducer 細節 |
| $\delta$ | **Reducer**：「run inside database transactions… If a reducer fails, all changes are automatically rolled back」；「Reducers are isolated and cannot interact with the outside world - they can only perform database operations」 | ✅ |
| $\rho$ / $C_t$ | **沒有對應物**。外部 I/O 走 **Procedure**：「Procedures can make HTTP requests… procedures don't automatically run in database transactions - they must manually open and commit transactions」。即：外部資料的取得**不在 $\delta$ 內、也不被當作 $C$ 記錄**，而是另一種可自行開 transaction 的函數 | ✅ |
| $\pi_k$ | 兩層：table 的 public/private；**Views**（server 端 read-only 函數）「filter rows, select specific columns, or join data… before exposing it」，且可被訂閱。但 client 是「Subscribe with queries to the data you need」——**訂閱範圍由 client 決定**，server 用 view/public 限制上界 | ✅ |
| Replay | 文件未提及 replay 或 re-evaluation 驗證功能；有 durability 但沒有「用記錄的 $(A, C)$ 重跑 $\delta$ 並比對」的機制 | ✅（未提及 ≠ 不存在，需再查 commit log 相關頁） |
| 決定性 | 文件未宣稱決定性；reducer 內時間／亂數由 `ReducerContext` 提供 | ⚠️ |

**用模型語言講**：SpacetimeDB 滿足 L1、L2；L3 的做法是「**禁止**」而非「隔離＋記錄」——reducer 不能碰 $E$，需要 $E$ 的邏輯被推到 procedure，而 procedure 本身不受 L2/L3 約束；L4 部分滿足（view 是 server 宣告，但訂閱是 client 選）。

**跟 SST 的差異落點**：
1. **$\rho$ 的存在**：SST 讓 $E$ 的結果以 $C$ 的形式進入 $\delta$ 且被記錄；SpacetimeDB 把需要 $E$ 的邏輯整個移出決定性邊界。後果：SST 的 replay 可以覆蓋依賴外部資料的 transition，SpacetimeDB 的 procedure 路徑不可重放。
2. **$\pi$ 的方向**：SST 是 server 在型別上宣告「誰看什麼」；SpacetimeDB 是 client 選、server 限。
3. **$S$ 的形狀**：tree vs relational。影響 diff 的粒度（path-based opcode vs row insert/update/delete）。
4. **形態**：嵌入式 library vs 獨立資料庫產品。這是取捨不是優劣。

**關於 replay 的精確措辭**（避免被反打）：
- SpacetimeDB **有** storage-level 的 durability（commit log，⚠️ 待查證其是否為 redo log 形式），可還原 $S$ 的結果序列。
- 它**沒有**（文件未提）transition-level 的 re-evaluation：記錄 $(A_t, C_t)$、重跑 $\delta$、比對結果。
- 關鍵證據是 procedure 的設計：「don't automatically run in database transactions」且結果不被記錄。若 re-evaluation 是設計約束，procedure 不會被這樣設計。這說明其決定性是 **transaction 正確性（abort / retry）的手段，而非重評估的手段**。
- 論文寫法：主張放在模型層（「procedure 位於 $\delta$ 之外，故不可重評估」），不放在功能層（「他們沒有 replay」），因為後者他們隨時可以補；前者是設計點的必然後果。加「as of version X」。
- 即使他們日後加上 replay，**跨架構 hash 驗證**（驗證 $\delta$ 本身的決定性，而非還原狀態）仍是 SST 獨有，要與 replay 分開講。

**風險**：SpacetimeDB 是上線產品、有 BitCraft 規模案例。論文若不主動比較，審稿人一提就是致命傷。**必須成為主要比較對象。**

---

### 1.2 Colyseus

| 模型元素 | Colyseus 的對應 | 查證 |
|---|---|---|
| $S_t$ | `Schema` class（「defined on the backend and describe data that is continuously synchronized」） | ✅ |
| $A_t$ | `onMessage` handler、`setSimulationInterval` tick | ⚠️ |
| $\delta$ | 任意 JS 程式碼，可直接改 state，**無純粹性約束**，可在任何地方 `await` 外部 I/O | ⚠️（文件未強制，屬設計事實） |
| $\rho$ / $C_t$ | 無 | ✅（文件無此概念） |
| $\pi_k$ | **StateView**：`.view(tag)` 標記欄位，「visible only to StateView instances that contain that Schema instance」；「Each StateView instance is going to add a new encoding step」——**server 端、encode 時過濾**，方向與 SST 相同 | ✅ |
| Replay | 「no mention of built-in replay or deterministic simulation」 | ✅ |
| 同步編碼 | binary delta；full state on join + tick patches | ✅ |

**用模型語言講**：滿足 L1（room state）、L4（StateView 是 server 宣告的 $\pi$）；**不滿足 L2、L3**——state 可從任何地方改，$E$ 可直接混入。因此 replay 在模型上不可得。

**跟 SST 的差異**：$\pi$ 的機制幾乎同構（欄位標記 + encode 時過濾），差在 L2/L3。這意味著跟 Colyseus 比 bandwidth 只能證明編碼效率，**證明不了模型的價值**；模型價值要靠「Colyseus 做不到 replay」來講。

---

### 1.3 Temporal（Durable Execution）

| 模型元素 | Temporal 的對應 | 查證 |
|---|---|---|
| $S_t$ | workflow 的本地變數（隱式，由 replay 重建，**不是可訂閱的資料結構**） | ✅ |
| $A_t$ | signal、timer、activity completion 等 event | ✅ |
| $\delta$ | workflow code：「It has to make the same decisions when given the same history」；禁止 `Date.now()`、random、network | ✅ |
| $\rho$ / $C_t$ | **Activity**：「the Activity runs once, its result is recorded in the Event History. During replay, that result is reused, not recomputed」 | ✅ |
| $\pi_k$ | **無**——workflow 沒有多讀者投影的概念 | ✅ |
| Replay | 核心機制：「starts the Workflow code from the beginning, replays the Event History step by step」 | ✅ |

**用模型語言講**：L2、L3 滿足得**比 SST 更嚴格**（runtime 會偵測 non-determinism）；L1 弱（狀態隱式）；**L4 不存在**。

**跟 SST 的差異**：
1. $\rho$ 的**時機**：Temporal 的 activity 在 $\delta$ **中間**被呼叫（workflow 是 async、交錯執行），SST 的 resolver 在 $\delta$ **之前**全部並行完成，$\delta$ 因此可以是同步、在 actor 內原子執行——對 20 Hz tick 系統這是必要條件。
2. $\rho$ 的**綁定方式**：Temporal 動態（跑到才知道呼叫哪個 activity，所以需要 non-determinism detection 抓改版後 history 對不上）；SST 靜態宣告在 action 上（`HandleAction(X.self, resolvers: (A.self, B.self))`）。
3. **沒有 $\pi$**：Temporal 是單一 workflow 的 durable execution，不是多讀者的即時狀態同步。

**這是 SST 的「決定性重放」半邊最強的先行者，論文必須承認並定位為同一家族。**

---

### 1.4 Photon Quantum ⚠️（文件被防爬牆擋住，全部憑既有知識，寫進論文前務必查證）

| 模型元素 | Quantum 的對應 |
|---|---|
| $S_t$ | Frame（ECS 世界狀態），**在每個 client 上各自模擬** |
| $A_t$ | 玩家 input（唯一在網路上傳輸的東西） |
| $\delta$ | 決定性模擬（fixed-point math、固定 tick） |
| $\rho$ / $C_t$ | **無**——模型假設 $E = \emptyset$，世界完全由 input 決定；沒有外部資料的概念 |
| $\pi_k$ | **無**——每個 client 有完整世界 |
| Replay | 有（錄 input 即可重放） |
| 權威 | server 只 relay 並排序 input；**不是 server-authoritative**，靠 predict/rollback |

**用模型語言講**：L2、L3 以「$E$ 不存在」的方式極端滿足；L1、L4 **反向**——狀態在每個 client 複製，沒有投影。

**跟 SST 的差異**：Quantum 證明了「決定性 + 只傳 input」在遊戲裡可行，但它放棄了 server authority 與資訊隱藏，也無法接外部資料。SST 是「保留 server authority 與 $\pi$ 的前提下取得決定性」。

---

### 1.5 Event Sourcing / CQRS（模式，非產品）

| 模型元素 | 對應 |
|---|---|
| $S_t$ | $\text{fold}(events)$ |
| $A_t$ | command → event |
| $\delta$ | event handler / aggregate |
| $\rho$ / $C_t$ | 無標準做法；常見是 command handler 內做 I/O 後把結果**寫進 event**（即：把 $C$ 併進 $A$） |
| $\pi_k$ | read-model projection（**批次／最終一致**，非即時推送） |
| Replay | 核心能力 |

**用模型語言講**：SST 可視為「即時、多讀者、$\rho$ 被明確分離出來」的 event sourcing 特例。「把 $C$ 併進 $A$」跟「$C$ 獨立記錄」在重放上等價，差別在 $\rho$ 可否並行、可否在 $\delta$ 前失敗中止（草稿 §3.1.5 的 failure semantics）。

---

## 2. 對照矩陣

| | L1 單一權威 $S$ | L2 只經 $\delta$ 改 | L3 $E$ 隔離＋記錄 | L4 宣告式 $\pi$ | $\rho$ 時機 | Replay 驗證 | 即時推送 | 形態 |
|---|---|---|---|---|---|---|---|---|
| **SST** | ✓ tree | ✓ actor | ✓ Resolver 記錄 | ✓ server 宣告、型別上 | $\delta$ 之前，並行 | ✓ 跨架構 hash | ✓ | library |
| SpacetimeDB | ✓ tables | ✓ reducer (tx) | **✗ 禁止**（走 procedure，不記錄） | △ server view 限上界，client 選 | — | ✗（未提及） | ✓ | 資料庫產品 |
| Colyseus | ✓ schema | ✗ | ✗ | ✓ StateView | — | ✗ | ✓ | library |
| Temporal | △ 隱式 | ✓ | ✓ Activity 記錄 | **✗ 無** | $\delta$ 之中，交錯 | ✓ history replay | ✗ | 平台 |
| Photon Quantum ⚠️ | ✗ 每 client 複製 | ✓ | △ $E=\emptyset$ | ✗ 無 | — | ✓ input replay | ✓ | SDK |
| Event Sourcing | ✓ | ✓ | △ 併入 $A$ | △ projection，非即時 | 無定義 | ✓ | ✗ 通常批次 | 模式 |

**讀法**：SST 是唯一同時打勾 L3（隔離＋記錄）與 L4（宣告式 $\pi$）且即時推送的一列。最接近的兩個鄰居各缺一邊：SpacetimeDB 缺 L3 的「記錄」半邊（它用禁止取代），Temporal 缺 L4。

---

## 3. 模型是否能描述這些系統？（自我檢驗）

用模型語言描述時遇到的**不順**，代表模型可能有洞：

1. **SpacetimeDB 的 procedure 放哪？** 它既不是 $\delta$（不受 tx 約束、可做 I/O）也不是 $\rho$（不產生 $C$ 給 $\delta$）。模型目前沒有「決定性邊界之外的合法邏輯」這個位置。→ 論文可以把這點講成「SpacetimeDB 選擇把 $E$ 相依邏輯**移出模型**，SST 選擇把它**收進 $C$**」，這是一個明確的設計軸。
2. **Temporal 的 $S$ 是隱式的。** 模型假設 $S$ 是顯式資料結構；Temporal 的狀態是程式執行點。模型描述得出來（$S$ = 本地變數），但 L1「單一快照」對它意義不大。→ 說明 L1 對 L4 是必要條件（沒有顯式 $S$ 就沒東西可投影），這反而加強 L1 的理由。
3. **$\rho$ 的時機沒有寫進模型的限制裡。** 草稿 §3.1.3 有講 eager parallel，但四條限制 L1–L4 沒有一條規定「$\rho$ 必須在 $\delta$ 之前完成」。Temporal 的交錯式 $\rho$ 也滿足 L3。→ 若要把「$\delta$ 同步、可在 actor 內原子執行」當成 SST 的性質，**需要新增一條限制 L5：$\rho$ 與 $\delta$ 分階段（phase-separated）**。這是本次對照發現的最具體的模型修正。
4. **Quantum 的「$E = \emptyset$」是 L3 的退化情況。** 模型描述得出來，但要說明 L3 在 $E = \emptyset$ 時自動成立，因此 Quantum 不需要 $\rho$。
5. **Input log vs. output log 是更根本的分類軸。**
   - Output log（redo log / WAL，SpacetimeDB commit log）：記 $S_t \to S_{t+1}$ 的結果。可還原 $S$，但 $\delta$ 不參與，因此無法驗證 $\delta$ 的決定性、無法做 regression、無法換 $C_t$ 做 what-if、無法定位邏輯錯誤發生在哪一步。
   - Input log（SST、state machine replication 的 command log）：記 $(A_t, C_t)$ 與 $S_0$，重跑 $\delta$ 並比對。
   - **因果關係**：選 output log 的系統永遠不需要 $\rho$（外部資料的結果已寫進 row）；選 input log 的系統**必須**有 $\rho$ 且記錄 $C_t$，否則 $\delta$ 重跑時缺參數。Resolver 不是額外功能，是 input-log 路線的必然產物。
   - 論文連結：SMR（Raft 等）的 log 存 command 而非結果，SST 等於把 SMR 的 input-log 思路用於單機即時狀態演化，並以 $C_t$ 處理 SMR 假設不存在的外部非決定性。這個定位對分散式系統背景的審稿人有效。
   - 這一軸應寫進模型（可作為 L3 的動機說明），並在矩陣加一欄「log 類型」。

---

## 4. 對改稿的直接影響

1. **Related Work 重排**：SpacetimeDB 與 Temporal 放最前面，各一段 + 上面那張矩陣；Colyseus / Photon 降為「同步機制」層級的比較。
2. **貢獻列表重寫**：
   - 降級：單一權威樹、宣告式同步（SpacetimeDB / Colyseus 都有）
   - 升級：**$\rho$ 的 phase-separated 設計**（vs Temporal）、**L3 以記錄而非禁止實現**（vs SpacetimeDB）、**跨架構 replay 驗證**（無人有）
3. **模型新增 L5**（$\rho$ / $\delta$ 分階段），並說明它推導出「$\delta$ 可同步、可原子」。
4. **補一個只有 $\rho$ 才能做的實驗**：一個 action 依賴外部 DB 查詢，展示 (a) live 時 resolver 輸出被記錄、(b) replay 時 resolver 被跳過、state hash 仍一致、(c) 換掉 resolver 輸出可做 what-if 分析。這是 SpacetimeDB 與 Colyseus 都做不到的事，一個實驗立住差異。
5. **待查證清單**（寫進論文前）：
   - [ ] SpacetimeDB：commit log / 是否有任何 replay 或 time-travel 功能；`ReducerContext` 的 timestamp / rng 來源；scheduled reducer 語意
   - [ ] SpacetimeDB：subscription 是否有 server 端強制的 RLS（本次抓到的文件只提 view 與 public/private）
   - [ ] Photon Quantum：整節重新對照官方文件
   - [ ] Colyseus：`onMessage` / simulation interval 的執行模型（是否單執行緒、是否可 await）
   - [ ] 補查：Nakama、Rivet、Ambient、Bevy Replicon——確認沒有第二個「L3 記錄 + L4」的實例

---

## 5. 一句話定位（供 abstract 用）

> StateTree 將「權威狀態 + 決定性轉換 + 多讀者投影」這類正在興起的系統形式化為一個 programming model，並指出其中一個被現有系統忽略或以禁止取代的維度——**非決定性的階段分離、隔離與記錄**——使得依賴外部資料的狀態演化仍可被重放與驗證。SwiftStateTree 為此模型的參考實作；SpacetimeDB、Colyseus、Temporal 可視為此模型在不同設計點上的實例。
