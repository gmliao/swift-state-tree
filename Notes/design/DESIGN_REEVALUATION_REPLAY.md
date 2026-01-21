# Re-evaluation（Action / Rule）vs 傳統 Replay

> 本文檔系統化地說明 SwiftStateTree 的 **Re-evaluation** 能力（Action / Rule 兩種重評估方式）與「傳統 replay 做法」的差異。
>
> 適用於：
> - 論文的 **conceptual comparison section**
> - SST 文件的 **core concept 定義**
> - 對外說明時避免被誤解
>
> 本文檔使用**模型／語義層**來描述，而非工程細節。

> 名詞對齊（使用 SwiftStateTree 現有用語）：  
> - 本文的 **input** 對應到系統中的 **`Tick` / `Action(payload)` / `Event(payload)`**（它們是狀態轉換的直接驅動）。  
> - 本文的 **resolved context** 對應到 **透過 `Resolver` 在執行前 resolve 出來、注入 `LandContext` 的資料集合**（本質上是「已解決的外部世界條件」）。  
> - `Resolver` 的輸出是 **`ResolverOutput`**：它**不進 `StateTree`、不 sync / diff**，但在 Re-evaluation 的語義下，**其 resolved 結果必須能被保存到 replay log**（作為可重算因果鏈的一部分）。

---

## 零、SST 的 Re-evaluation 能力與兩種重評估方式

SwiftStateTree（SST）所謂的 replay，核心能力不是「回放結果」，而是**在固定條件下重新執行狀態轉換邏輯**（re-evaluate state transitions）。在此框架下，系統支援兩種彼此獨立（orthogonal）的重評估方式：

- **Action Re-evaluation**：在固定 `Rules/Config` 與 resolvedContext（`ResolverOutput` → `LandContext`）下，變動 `Action(payload)` / `Event(payload)`（或其注入時點）與/或 initial state，以比較因果路徑差異。
- **Rule Re-evaluation**：在固定 input timeline（依 `tickId` 的 `Tick`/`Action`/`Event` 序列）與 resolvedContext 下，變動 `Rules/Config`（規則／系統參數），以評估可行性、穩健性與平衡性。

以下章節分別正式定義 Action Re-evaluation 與 Rule Re-evaluation，並釐清其差異。

---

## 一、核心定義對照

### 傳統 Replay（State Snapshot / Event Log Playback）

> **Replay = 重現已發生的結果**

* 歷史是已鎖死的
* replay 是播放
* 系統不再「推理」

---

### SwiftStateTree：Action Re-evaluation

> **Replay = 在固定的世界條件（由 `Resolver` resolve 並凍結的 `resolved context`）下，  
> 重新執行決定性的狀態轉換邏輯（`Tick` / `Action` / `Event` handlers）**

* 歷史是可被重新運行的
* replay 是重新計算
* 系統仍在「推理」

---

## 二、能力層級差異

| 面向             | 傳統 Replay        | SwiftStateTree：Action Re-evaluation |
| -------------- | ---------------- | ------------------ |
| Replay 的對象     | State snapshot / event log | **Land 的狀態轉換邏輯（`Tick`/`Action`/`Event` handlers）** |
| 非決定性來源         | 已隱含在歷史中          | **被顯式封裝為 `ResolverOutput`，注入 `LandContext` 並可被保存** |
| Replay 時是否重新計算 | 否（套資料）           | **是（重新 evaluate handlers）** |
| 結果是否必須一致       | 不要求              | **必須一致**           |
| 能否解釋「為什麼」      | 否                | **是**              |
| 能否重播           | 可以               | 可以                 |
| 能否重玩（re-run）   | 不保證              | **保證**             |
| 能否做 what-if    | 幾乎不可能            | **原生支援**           |
| 能否分支比較         | 否                | **是**              |

---

## 三、關鍵差異一：Replay 的「本體」不同

### 傳統做法的 replay 本體是：

> 「**已記錄的歷史資料**」

* replay = 重放資料
* 系統邏輯不再被執行
* 因果只存在於記錄中

---

### Action Re-evaluation 的 replay 本體是：

> 「**決定性的狀態轉換（handlers）**」

形式上就是：

```
state′ = transition(state, input, resolvedContext)

where
- input ∈ { Tick, Action(payload), Event(payload) }
- resolvedContext = `Resolver` 的 resolved outputs（`ResolverOutput`...）+ request metadata（例如 tickId / playerID / sessionID）
```

* replay = 重新執行 transition（也就是重新跑 handlers）
* resolvedContext 是已凍結的世界條件（由 Resolver resolve 後的結果）
* 因果是可再運行的

---

## 四、關鍵差異二：非決定性的處理方式

### 傳統 Replay

* 時間、random、IO、外部查詢結果
* 已經「滲入」歷史
* replay 時無法分離

結果是：

> 你只能接受「事情已經這樣發生了」

---

### Action Re-evaluation（SwiftStateTree）

* 所有非決定性 → **`Resolver`**
* `Resolver.resolve(...)` → 產生 **`ResolverOutput`**
* `ResolverOutput` 被注入 **`LandContext`**（Action/Event/Tick 執行前完成 resolve，確保 handler 本身是 deterministic 的）
* 對 Action Re-evaluation 而言：**`ResolverOutput` 的 resolved 結果必須可被保存到 replay log**，以便重播時能用相同的 resolved inputs 重新跑同一段 handlers

結果是：

> 世界條件被凍結，
> 狀態演化變成可重算的函數

---

## 五、關鍵差異三：能不能做「對照實驗」

### 傳統 Replay 能做的是：

* 看歷史
* 找關聯
* 比較結果

這是：

> **描述式／鑑識式分析**

---

### Action Re-evaluation 能做的是：

* 固定 `Rules/Config`（規則／系統參數不變）
* 固定 resolvedContext（同一組 `ResolverOutput` → `LandContext`）
* 變動項僅限於：
  - input：改變某些 `Action(payload)` / `Event(payload)`（或其注入時點，例如特定 `tickId`）
  - initial state：以不同的起始 state（例如不同 baseline snapshot）作為重評估起點
* 比較整條演化路徑

這是：

> **可介入、可分支的因果分析**

也就是：

> 「保留部分狀態，修改部分狀態，在相同執行條件下跑結果」

> 註：若變動項是 `Rules/Config`（規則／系統參數），而 input timeline 與 resolvedContext 保持不變，則屬於 Rule Re-evaluation（見「Action vs Rule Re-evaluation」段落）。

---

## 六、Replay vs Re-evaluation

可用下列方式區分：

* 傳統 replay：

  > **replay = reproduce outcomes**

* SwiftStateTree 的 Action Re-evaluation：

  > **replay = re-evaluate `Tick`/`Action`/`Event` state transitions**

此區分用於強調「回放結果」與「重評估狀態轉換」的語義差異。

---

## 七、為什麼這不是「實作技巧差異」，而是模型差異？

因為：

* 傳統 replay **不要求** transition 是純的
* Action Re-evaluation **強制要求** transition 是決定性的

這代表：

* Action Re-evaluation 是一個**語義約束**
* 不是事後補 log 能補出來的能力

---

## 八、總結

> **Traditional replay treats history as immutable recordings.
> Deterministic Re-evaluation Replay treats history as a reproducible computation under fixed world conditions.**

或中文版：

> **傳統 replay 保存的是「發生過的結果」；
> Action Re-evaluation 保存的是「可被再次運行的因果結構」。**

---

## 九、概念擴充：Rule Re-evaluation

### 命名

**Rule Re-evaluation**  

- **Re-evaluation**：強調「重新執行狀態轉換邏輯」（不是回放結果）
- **Rule-Variant**：明確指出「規則／系統參數」是變數
- **對稱性**：與 Action Re-evaluation 形成平行概念對（Action vs Rule）

> 註：本概念與 Action Re-evaluation 形成對稱延伸（Action vs Rule）。

---

### 正式定義（English, ready for paper）

> **Rule Re-evaluation**  
> Rule re-evaluation denotes a form of re-evaluation in which a fixed input timeline is re-executed under different rule or system parameter variants, while preserving the original execution order and resolved world context.  
> The purpose of rule re-evaluation is to evaluate the feasibility, robustness, or balance of a given rule set by observing whether an identical sequence of inputs can still reach a target or terminal state under alternative rule assumptions.

> 對齊 SwiftStateTree 用語：  
> - **fixed input timeline**：依 `tickId` 排序的 `Tick` / `Action(payload)` / `Event(payload)` 序列（輸入時序不變）  
> - **resolved world context**：由 `Resolver` resolve 後注入 `LandContext` 的 `ResolverOutput` 集合（世界條件不變）  
> - **rule / system parameter variants**：Land 的規則或系統參數變體（例如 `Rules` / `Config` 或 handler 內部使用的 rule parameters）

---

### 正式定義（中文版，對齊系統用語）

> **規則重評估（Rule Re-evaluation）**  
> Rule re-evaluation 指的是在保持「輸入時序」（依 `tickId` 排序的 `Tick` / `Action(payload)` / `Event(payload)`）與「已解決的世界條件」（由 `Resolver` resolve 並注入 `LandContext` 的 `ResolverOutput`）不變的前提下，  
> 對不同的規則或系統參數變體進行重新執行，  
> 以評估該輸入序列在不同規則假設下是否仍能到達目標狀態或終止狀態。
>
> Rule re-evaluation 的目的不在於比較決策品質，而在於分析規則設計對可行性、難度與系統穩定性的影響。

---

## 十、Action vs Rule Re-evaluation：兩條正交的重評估軸線

| 面向 | Action Re-evaluation | Rule Re-evaluation |
| --- | --- | --- |
| **固定項** | 規則 / 系統參數（rule set）與 resolvedContext（`ResolverOutput` → `LandContext`） | 輸入時序（依 `tickId` 的 `Tick`/`Action`/`Event` timeline）與 resolvedContext（`ResolverOutput` → `LandContext`） |
| **變動項** | 輸入（例如改變某些 `Action(payload)` / `Event(payload)`，或在特定 `tickId` 注入不同 input） | 規則 / 系統參數（rule / system parameters） |
| **核心問題** | 「如果當時做了不同輸入，結果會怎樣？」 | 「如果規則不同，這條輸入序列還走得通嗎？」 |
| **分析焦點** | input 介入對因果鏈的影響（what-if / strategy） | 規則變體對可行性、穩健性、平衡性的影響（validation / balancing） |

---

## 十一、界線宣告（避免混概念）

> *It is important to note that action re-evaluation and rule re-evaluation represent two orthogonal axes of re-evaluation. Mixing input intervention and rule modification within the same experimental run would compromise causal interpretability and is therefore intentionally avoided in SwiftStateTree.*

中文版：

> **Action Re-evaluation 與 Rule Re-evaluation 分別對應於輸入空間與規則空間的重評估，  
> 在 SwiftStateTree 中被視為兩條正交的分析軸線，  
> 不應在同一實驗中混合使用，以維持因果可解釋性。**

---

## 十二、總定錨句（一句話總覽）

> **Action Re-evaluation 回答的是「如果我當時送出不同的 `Action/Event`（或在不同 `tickId` 注入不同輸入）會怎樣」；  
> Rule Re-evaluation 回答的是「如果 `Rules/Config`（規則／系統參數）不同，這些輸入還走得通嗎」。**

## 相關文檔

* [DESIGN_TICKID_REPLAY.md](./DESIGN_TICKID_REPLAY.md) - TickId 綁定機制用於重播（實作細節）
* [DESIGN_CORE.md](./DESIGN_CORE.md) - 核心概念：整體理念、StateTree、同步規則
* [DESIGN_RUNTIME.md](./DESIGN_RUNTIME.md) - Runtime 設計與執行機制
* [DESIGN_STATE_RESOLVE.md](./DESIGN_STATE_RESOLVE.md) - Resolver / ResolverOutput / LandContext 的語義與資料流

