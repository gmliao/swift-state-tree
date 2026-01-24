# Actor Reentrancy 與狀態更新阻塞風險（技術說明）

## 摘要（Abstract）

本文描述在以 Swift `actor` 封裝「每房間（room）」狀態的伺服器架構中，若將 Action Handler 設計為 `async` 且在狀態更新流程中引入多個 `await`，可能造成 **狀態更新非原子（non-atomic）**、**tick/sync 的時序不確定性**，以及在高負載下的 **延遲與吞吐惡化**。本文亦說明「Resolver 與 Action 分離」如何將非同步 I/O 從 actor 的臨界區移出，以降低上述風險。

---

## 1. 執行模型（Execution Model）

### 1.1 Actor 隔離與 reentrancy

Swift `actor` 提供資料隔離（isolation）：同一時間只有一段 actor-isolated 程式碼在執行 **直到遇到 suspension point**。  
當 actor-isolated 函式執行到 `await` 時，該函式會暫停（suspend），而 actor **可能允許其他排隊中的工作在其間插入執行**（reentrancy）。因此：

- `await` **不一定等同「整個 actor 被鎖死」**；更精確地說，是「在 `await` 之前的區段被序列化，但 `await` 之後可能與其他工作交錯」。
- 這種交錯在語義上會導致：若狀態更新跨越多個 `await`，就難以保證「Action → tick → sync」的預期順序與原子性。

### 1.2 問題定義

在每房間一個 `LandKeeper`（actor）的設計中，常見的房間內工作包含：

- **Action**：處理玩家輸入並更新狀態
- **Tick**：週期性遊戲邏輯更新
- **Sync**：對外輸出狀態差異（snapshot/diff）

本文關注的是：**當 Action Handler 本身是 `async` 且包含多個 `await` 時，tick/sync 與 action 的交錯會如何影響正確性與效能。**

---

## 2. 風險分析（Risk Analysis）

### 2.1 非原子狀態更新（Non-atomic mutation）

若 Action Handler 的狀態更新跨越 `await`，典型風險是：

- tick/sync 可能在 Action 尚未完成前插入，觀察到「尚未完成」或「延後生效」的狀態
- 若 Action 在 `await` 前後都有 mutation，則可能出現部分更新已寫入、部分更新尚未寫入的中間狀態

以下示意（只做概念展示）：

```swift
actor LandKeeper {
    func handleAction(action: Action) async {
        state.a = 1               // mutation (phase 1)
        let x = await fetchX()    // suspension point
        state.b = x               // mutation (phase 2)
    }
}
```

在 `await fetchX()` 期間，`tick()` 或 `sync()` 可能插入並讀到 `a=1` 但 `b` 尚未更新的狀態。

### 2.2 時序不確定（Ordering non-determinism）

對遊戲伺服器而言，常見的期望是：

1. Action 先完成狀態更新
2. Tick 基於最新狀態運行
3. Sync 將最新狀態對外發布

當 Action Handler 是 `async` 且含 `await` 時，上述順序在同一 actor 內可能出現交錯，導致「tick/sync 基於較舊狀態執行」或「sync 推送延後」等現象。

### 2.3 簡化效能模型（Throughput / Latency）

即使 actor 在 `await` 期間允許 reentrancy，机理上仍存在「狀態更新完成時間」被外部 I/O 延長的問題。  
令：

- $T_{io}$：Action 內等待外部 I/O 的時間（例如 DB / HTTP）
- $T_{mut}$：純狀態 mutation 與同步前置計算時間
- $T_{act} = T_{io} + T_{mut}$：單個 Action 的完成時間（completion latency）

則在「要求 Action 完成後才視為狀態生效」的語義下：

- **狀態生效延遲（state-visibility latency）** 至少為 $T_{act}$
- 若同一房間內 Action 到達率為 $\lambda$，且每次 Action 的「actor 內臨界區」平均時間為 $T_{cs}$（例如 mutation + 編碼 + 少量同步計算），則粗略可用利用率近似：

$$
\rho \approx \lambda \cdot T_{cs}
$$

當 $\rho \to 1$ 時，排隊延遲會急遽增加，tick/sync 也更容易落後（back-pressure）。

---

## 3. 示例：時間軸與可觀察行為（Illustrative Example）

以下以單一房間為例，假設同一房間內存在三類事件：Action、Tick、Sync。  
Action 需要等待三個外部操作（僅用於展示）：

- $\texttt{await loadProductInfo()}$：50 ms  
- $\texttt{await loadUserProfile()}$：30 ms  
- $\texttt{await loadInventory()}$：40 ms  

### 3.1 Action Handler 為 async（跨越多個 await）

| 時間 | 事件 | actor 內狀態 | 對 tick/sync 的含義 |
|------|------|--------------|----------------------|
| 0 ms | Action 開始 | 進入 handler | handler 執行到第一個 `await` 前為序列化區段 |
| 0–50 ms | `await loadProductInfo()` | handler 暫停（可 reenter） | tick/sync **可能插入**，但狀態更新尚未完成 |
| 50–80 ms | `await loadUserProfile()` | handler 暫停（可 reenter） | 同上 |
| 80–120 ms | `await loadInventory()` | handler 暫停（可 reenter） | 同上 |
| 120 ms | handler 恢復並完成 mutation | 狀態更新完成 | 後續 tick/sync 才能保證看見更新後狀態 |

重點不是「tick/sync 完全不能跑」，而是：

- tick/sync 可能在 Action 完成前執行，導致 **基於舊狀態計算** 或 **發布舊狀態**
- 若 handler 在 `await` 前已做部分 mutation，則可能暴露 **中間狀態**

---

## 4. 緩解策略：Resolver 與 Action 分離（Mitigation）

### 4.1 兩階段（two-phase）設計

將一次 action 處理拆為兩個階段：

1. **非同步資料取得（async, parallelizable）**：在 actor 臨界區之外取得所需資料（Resolver）
2. **同步狀態提交（sync, atomic commit）**：回到 actor 內以同步方式一次性寫入狀態（Action Handler）

其目標是讓 actor 內部的狀態 mutation 保持「短、同步、可推理」。

### 4.2 形式化描述

令 Resolver 輸出為 $C$（context），狀態為 $S$，Action 為 $A$。  
期望的狀態轉移可寫成：

$S' = f(S, A, C)$

其中 $C$ 可以由多個 resolver 並行計算：

$C = g(r_1, r_2, \ldots, r_k)$

關鍵是：**計算 $C$ 的過程不直接修改 $S$**，並且 $f$ 在 actor 內同步執行，避免跨 `await`。

### 4.3 參考程式形狀（概念示例）

```swift
// Phase 1: resolve outside the actor (can be parallel)
let ctx = try await resolverExecutor.resolveAll(...)

// Phase 2: atomic state commit inside the actor (sync / short)
await landKeeper.commit(action: action, ctx: ctx) { state, action, ctx in
    // synchronous mutation only
    state.updateFrom(ctx, action)
}
```

---

## 5. 實務建議（Practical Guidelines）

1. **避免在 actor 內的狀態 mutation 流程中跨越 `await`**  
   - 若必須等待 I/O，將其移到 actor 外（Resolver / service layer）。

2. **將 Action Handler 設計為同步的「原子提交（atomic commit）」**  
   - handler 執行時間應盡可能短且可預測。

3. **將 tick/sync 視為「對狀態一致性敏感」的工作**  
   - 若 tick/sync 要求「一定看見最新 action」，則更需要避免 async handler 造成交錯。

---

## 6. 限制與討論（Limitations）

- 本文使用簡化模型描述行為；實際 interleaving 取決於 Swift runtime 排程、工作到達率與系統負載。
- reentrancy 雖能提升吞吐，但也會引入推理複雜度（尤其是跨 await 的不變量維護）。因此本文偏好「縮小 actor 臨界區」的設計取向。

---

## 7. 結論（Conclusion）

當 Action Handler 為 `async` 並在狀態更新流程中包含 `await` 時，actor reentrancy 會使 tick/sync 與 action 的執行時序更不確定，並可能破壞狀態更新的原子性與可推理性。  
採用「Resolver（async）與 Action（sync commit）分離」可將外部等待移出 actor 臨界區，降低阻塞風險並改善一致性與可維護性。

