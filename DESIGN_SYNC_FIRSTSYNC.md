# SwiftStateTree — First Sync（首次同步）設計規格

> 本文檔說明 SwiftStateTree 的首次同步機制，確保客戶端能夠安全且清楚地建立狀態 baseline 並開始接收差異更新。

## 🎯 目標

First Sync 用於解決以下問題：

* **客戶端剛加入房間時沒有任何 baseline 狀態**
* **同步引擎（SyncEngine）需要一個「起點」**
* **避免 snapshot 與 diff 混在一起產生 race condition**

因此設計出一個 **清楚且安全的啟動流程**：

```
Join → Snapshot → FirstSync → (開始 Diff)
```

---

## 📍 1. Join：取得完整初始狀態（Snapshot）

當玩家加入 Realm/Room 時，SwiftStateTree Runtime 會：

1. 建立 Session（playerID、clientID）
2. 根據 SyncPolicy 裁切 StateTree（broadcast + perPlayer）
3. 產生 **完整 snapshot**
4. 透過 RPC.join（系統級）回傳給客戶端

### 📥 客戶端收到的是完整狀態：

```json
{
  "players": {...},
  "hands": {...},
  "turn": "p1",
  "round": 1
}
```

### ✔ 這是一次性的初始快照，不是 diff

客戶端在這裡會：

* 建立本地 StateTree
* 設定 baseline
* 完成第一次渲染（UI）

**實作範例**：

```swift
// Server 處理 join RPC
case .join(let id, let name):
    state.players[id] = PlayerState(name: name, hpCurrent: 100, hpMax: 100)
    state.hands[id] = HandState(ownerID: id, cards: [])
    let snapshot = try syncEngine.snapshot(for: id, from: state)
    return .success(.joinResult(JoinResponse(realmID: ctx.realmID, state: snapshot)))
```

---

## 📍 2. FirstSync：告訴客戶端「同步引擎開始了」

當同步系統（SyncEngine）正式啟動時，伺服器會送出：

```json
{
  "firstSync": true,
  "patch": [...]
}
```

### ✔ `patch` 可能為空，也可能包含變化

`firstSync` 包含 patches 陣列，有兩種情況：

1. **Patch 為空**：如果 join 後到第一次 `generateDiff` 之間沒有狀態變化
2. **Patch 有內容**：如果 join 後到第一次 `generateDiff` 之間有狀態變化，這些變化會包含在 `firstSync` 的 patches 中

這樣設計的好處：
* 確保不會丟失任何變化
* 客戶端可以統一處理 patches（無論是 `firstSync` 還是 `diff`）

### ✔ 閱讀這包訊息的更重要目的：

> **通知客戶端：從現在起，開始接收 diff 更新。**

也就是：

* baseline 已建立（由 RPC.join snapshot 提供）
* SyncEngine 進入 operational mode
* 未來都會收到 patch（diff-based updates）

這個事件可以視為一次：

### 👉 「Sync Start 信號（同步啟動點）」

**實作範例**：

```swift
// Server 第一次為玩家生成 diff
let update = try syncEngine.generateDiff(for: playerID, from: state)
// 如果這是第一次（cache 為空），會返回 StateUpdate.firstSync([StatePatch])
// 客戶端收到後知道：從現在開始接收 diff 更新
// Patches 可能包含 join 後到第一次 generateDiff 之間的變化
```

**StateUpdate 定義**：

```swift
public enum StateUpdate: Equatable, Sendable {
    case noChange              // 沒有變化
    case firstSync([StatePatch]) // 首次同步信號（同步引擎啟動）+ 變化
    case diff([StatePatch])     // 差異更新
}
```

---

## 📍 3. diff-based Sync：開始進入常態同步流程

之後每次 Tick 或邏輯更新，伺服器都會送 diff：

```json
{ "patch": { "players.p1.hp": 80 } }
{ "patch": { "turn": "p2" } }
{ "patch": { "round": 3 } }
```

這些更新會依照補丁合併到客戶端本地 StateTree。

此時客戶端的狀態更新流程變成：

```
Snapshot (from join)
+ FirstSync (告訴你開始 diff)
+ Diff, Diff, Diff, Diff...
```

**實作範例**：

```swift
// Server 後續的狀態更新
let update = try syncEngine.generateDiff(for: playerID, from: state)
switch update {
case .noChange:
    // 沒有變化，不發送
case .firstSync(let patches):
    // 首次同步信號（只在第一次發生）+ 包含可能的變化
    await ctx.sendEvent(.stateUpdate(.firstSync(patches)), to: .player(playerID))
case .diff(let patches):
    // 差異更新
    await ctx.sendEvent(.stateUpdate(.diff(patches)), to: .player(playerID))
}
```

---

## 📍 4. 為什麼 FirstSync 一定要存在？

### 🟡 避免 snapshot 和 diff 交叉混亂

沒有 firstSync，就會出現典型 race condition：

* snapshot 正在初始化
* diff 在這時候突然抵達
* 客戶端不確定要 apply 還是忽略
* 有機會造成 UI 畫面錯亂或資料不一致

### 🟡 客戶端必須知道同步引擎開始運作

否則不知道什麼時候開始：

* 建立 local baseline
* 接受 diff
* 啟動本地 reducer / state listener

### 🟡 架構乾淨：RPC 與 SyncEngine 分離

* `join`：一次性 → snapshot
* `sync`：持續性 → diff

系統更穩定、邏輯更簡單、可測性更高。

---

## 📍 5. 流程總圖

```
Client -----------------------> Server

         join()

         ---------------------->

         <---------------------- snapshot（一次性）
           （完整狀態，建立 baseline）

         <---------------------- firstSync {patch:{}}
           （同步引擎啟動提醒）

         <---------------------- diff
         <---------------------- diff
         <---------------------- diff
```

### 詳細時序圖

```
時間軸：

T0: Client 發送 join RPC
T1: Server 處理 join，生成 snapshot
T2: Client 收到 snapshot，建立 baseline
T3: Server SyncEngine 第一次為該玩家生成 diff
T4: Server 發送 firstSync 信號
T5: Client 收到 firstSync，知道開始接收 diff
T6+: Server 持續發送 diff 更新
```

---

## 📍 6. 實作細節

### SyncEngine 的 firstSync 邏輯

當 `generateDiff` 第一次為某個玩家計算差異時（cache 為空），會返回 `StateUpdate.firstSync`：

```swift
public mutating func generateDiff<State: StateTreeProtocol>(
    for playerID: PlayerID,
    from state: State,
    onlyPaths: Set<String>? = nil
) throws -> StateUpdate {
    // 計算 broadcast diff
    let broadcastDiff = try computeBroadcastDiff(from: state, onlyPaths: ...)
    
    // 計算 perPlayer diff
    let perPlayerDiff = try computePerPlayerDiff(for: playerID, from: state, onlyPaths: ...)
    
    // 合併 patches
    let mergedPatches = mergePatches(broadcastDiff, perPlayerDiff)
    
    // 如果是第一次（cache 為空），返回 firstSync（包含 patches）
    let isFirstSync = (lastBroadcastSnapshot == nil) && (lastPerPlayerSnapshots[playerID] == nil)
    
    if isFirstSync {
        // 更新 cache
        // ...
        return .firstSync(mergedPatches)  // 包含實際的 patches
    }
    
    // 返回 diff
    if mergedPatches.isEmpty {
        return .noChange
    } else {
        return .diff(mergedPatches)
    }
}
```

### 客戶端處理邏輯

```swift
// Client 處理狀態更新
func handleStateUpdate(_ update: StateUpdate) {
    switch update {
    case .noChange:
        // 不做任何事
        break
        
    case .firstSync:
        // 標記同步引擎已啟動
        syncEngineStarted = true
        // 可以開始監聽後續的 diff 更新
        startListeningToDiffs()
        
    case .diff(let patches):
        // 確保已經收到 firstSync
        guard syncEngineStarted else {
            // 如果還沒收到 firstSync，可能是 race condition
            // 可以選擇等待或記錄錯誤
            return
        }
        // 應用差異更新到本地狀態
        applyPatches(patches)
    }
}
```

---

## 📍 7. 小結論

> **SwiftStateTree 採用「Join Snapshot + FirstSync + Diff」模式。**
> 
> `Join` 提供完整初始狀態；`FirstSync` 告知同步引擎啟動；後續皆以 `diff` 推動狀態更新。
> 
> 這個模式簡潔、安全，並符合大型即時系統的設計標準。

---

## 📍 8. 相關文檔

* [DESIGN_RUNTIME.md](./DESIGN_RUNTIME.md) - SyncEngine 實作細節
* [DESIGN_COMMUNICATION.md](./DESIGN_COMMUNICATION.md) - RPC 與 Event 通訊模式
* [DESIGN_CORE.md](./DESIGN_CORE.md) - 核心同步概念
* [DESIGN_EXAMPLES.md](./DESIGN_EXAMPLES.md) - 端到端範例

