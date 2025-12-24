以下是 **用你的語氣寫的版本**，
不是學術式、不是裝專業，
而是像你在寫 README、技術筆記、或跟朋友講話時的自然風格：
**誠懇、直接、清楚、務實、有工程感。**

這些就是 **StateTree Reactive Server Model 的限制（Constraints）**
—— 也就是這個架構之所以能成立、也之所以能穩定的「基本規則」。

---

# **StateTree Reactive Server Model – Constraints（以我的口氣整理版）**

下面這幾條其實不是我硬規定的，
而是在實作到一定程度後自然浮現的「必要條件」。
如果不遵守，整個模型就會失去一致性或變得混亂。

---

# **1. State 必須用 Swift struct（value semantics）**

為什麼？
因為 struct 有值語意，不會亂傳 reference，
這讓整棵狀態樹天然安全，也不會被外部隨便突變。

寫起來就是：

* 客戶端不能改
* 伺服器外部 code 不能改
* 只有 runtime 能在合法區域裡改

這是整個 StateTree 的地基。

---

# **2. 外部不能直接改 State，唯一能改的地方是 Action（Mutation Boundary）**

這是我後來才發現非常重要。

State 是不能亂動的，
能改的地方只有：

```swift
func apply(to state: inout State) {
    // 這裡才可以改
}
```

也就是說：

* Action 是唯一的突變入口
* Action scope 結束後狀態就固定下來（snapshot）
* Runtime 才能基於 snapshot 計算 diff

這樣做的好處是可預期、可追蹤、可回放，不會亂。

---

# **3. 所有狀態更新都要 Diff，而不是全量同步**

我不會把整棵樹傳給客戶端，
太浪費頻寬也沒必要。

StateTree 的規則是：

* Action 執行完 → runtime 檢查有沒有 dirty
* 如果有 → 基於 snapshot 計算 diff
* 只同步 diff 給相關玩家

這樣伺服器效能好、網路省、延遲低。

---

# **4. Resolver 只能讀資料，不能偷偷修改 State**

Resolver 的工作是「補資料」、「lazy hydrate」，
它不是拿來改 State 的。

也就是說 Resolver 做的是：

* 填資料
* 查資料庫
* 整理 domain type
* lazy load subtree

但不能：

* 改 State
* 發 Event
* 改其他地方的 node

狀態只能由 Action 來改。

---

# **5. StateNode 需要明確設定 Sync Policy**

每個欄位要怎麼同步不是寫死的，是宣告的：

```swift
@Sync(.broadcast)
var theme: String
```

政策分成：

* broadcast → 每個人都會拿到
* private → 只有本人看到
* none → 不同步
* delta → 有變化時才同步
* onDemand → 要用才拉內容

這樣 Tree 大小不受限制，
不會一開始就把所有東西塞給客戶端。

---

# **6. StateTree 有兩種模式：Active 與 Passive，不混用**

我整理到最後才知道必須分成兩種：

## **Active（房間模式）**

* 狀態一直存在
* 用在遊戲、多人互動
* 有持續的 diff sync

## **Passive（類 API 模式）**

* Action 結束就銷毀
* 不維護長期狀態

混在一起會亂掉，所以 StateTree 僅允許擇一。

---

# **7. 傳輸層不重要，Sync 語意才重要**

StateTree 不綁定 WebSocket 或 HTTP。

我要的是：

* sync 是 delta-based
* sync 有順序
* sync 保證完整

不管底層是：

* WebSocket
* HTTP/2
* QUIC
* Distributed Actor

都可以實作，只要符合 sync 的語意就好。

---

# **8. 整棵狀態樹必須可序列化（Codable）**

這很務實：

* 要 snapshot 就必須序列化
* 要 diff 就必須能比較
* 要存 Redis / DB 就必須能 encode/decode
* 要產生 schema ← macro 需要依賴 Codable meta

所以 StateNode 必須是 Codable。

---

# **9. State 更新必須是 deterministic（可預期的）**

Action 一定要：

* 沒有亂數（或亂數要 seed）
* 沒有不可控 side effects
* 同一輸入一定得到同一輸出

這樣才支援：

* replay（重播）
* debugging
* deterministic server
* fair game behavior

這是 reactive model 必備的特性。

---

# **10. 整個 StateTree Model 最重要的精神：

狀態是單一真相來源（Single Source of Truth）**

你不能：

* 同時維護兩份 state
* 有 cache version
* 有 shadow copy
* 嘗試在 state 外再放一份資料

所有資訊都要回到 StateTree 內部，
這樣整個 sync 才是可靠的。

---

