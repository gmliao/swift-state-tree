# 演化與架構對照 (Evolution & Architecture Comparison)

這份文件記錄了從傳統 MMO 開發架構（C++/C# Actor Model）演化至現代 Swift StateTree 架構的歷程，並提供了詳細的概念對照與 Virtual Code 範例，旨在幫助開發者快速理解新架構的設計哲學。

---

## 0️⃣ 前言：從 Actor 到 StateTree 的演化故事

### Phase 1: C++ 蠻荒時代 (The Raw Era)
在早期的 MMO 開發中，我們手寫 C++。所有的同步都是「位元級」的計較。
*   **特徵**：手動序列化 (BitStream)、指標操作、記憶體管理。
*   **痛點**：邏輯與底層網路高度耦合。一個 `float` 變數要同步，得在 Header 宣告、在建構子初始化、在 `Serialize()` 寫入、在 `Deserialize()` 讀取。一旦忘記一個步驟，封包錯位，全盤崩潰。

### Phase 2: C# 受管時代 (The Managed Era)
隨著 Unity 與 C# 的普及，我們引入了 Reflection 與 Attributes。
*   **特徵**：`[NetVar]` 屬性、自動掃描 Dirty Flags、GC 管理記憶體。
*   **痛點**：雖然開發變快了，但「狀態」與「行為」依然綁死在 `Actor` 物件上。
    *   **鎖的惡夢**：遊戲邏輯執行緒在改 HP，同步執行緒也在讀 HP 並清 Dirty Flag。為了安全，到處都是 `lock`，或者只能強迫單執行緒。
    *   **權限混亂**：Client 到底能不能改這個變數？`OwnerReadWrite` 這種權限設定讓 Server 驗證邏輯變得異常複雜。

### Phase 3: Swift 值型別時代 (The Value-Type Era)
StateTree 的誕生，是為了徹底解決「多執行緒同步」與「狀態管理」的衝突。
*   **核心哲學**：**狀態 (State) 與 行為 (Realm) 分離**。
*   **特徵**：
    *   **Immutable Snapshots**：利用 Swift 的 Value Type (Struct) 特性，每個 Tick 結束就是一張唯讀快照。同步執行緒可以慢慢算 Diff，完全不用鎖。
    *   **單向資料流**：Client 不再直接改變數，而是發送 Action (意圖)。只有 Server 能修改 StateTree。
    *   **宣告式同步**：`@Sync` 決定了欄位如何被看見，而不是由程式碼動態決定。

---

## 📊 架構資料流 (Architecture Data Flow)

```mermaid
flowchart LR
    Client((Client))
    
    subgraph Server [Server / Realm Runner]
        direction TB
        Action_Queue[Action Queue]
        Realm[Realm (Logic / Write)]
        StateTree[StateTree (Data / State)]
        Snapshot[Immutable Snapshot]
        SyncEngine[Sync Engine (Read Only)]
        
        RPC_Queue -->|Apply Intent| Realm
        Realm -->|Mutate| StateTree
        StateTree -.->|Copy on Tick| Snapshot
        Snapshot -->|Input| SyncEngine
    end

    Client -->|1. Send Action (move, attack)| Action_Queue
    SyncEngine -->|2. Compute View & Diff| SyncEngine
    SyncEngine -->|3. Send Binary Patch| Client
    Client -.->|4. Apply Patch| Client
```

---

## 1️⃣ 舊框架：Actor / NetVar / Command / Event / Framework

### 🧱 核心概念回顧（舊世界）

* **Actor**
  * 一個遊戲物件／邏輯實體
  * 裡面有很多 `NetVar` 當屬性（HP、位置、狀態…）
  * 也負責吃 Command、發 Event

* **NetVar**
  * 包一個欄位的值＋同步資訊（Ownership、DirtyFlag、UpdatedFlag）
  * 決定誰可以讀／寫／同步

* **ActorCommand**
  * client → server / server → client 的指令封包
  * 可能攜帶「要更新哪些 NetVar」

* **ActorEvent**
  * 廣播用的事件（例如：爆炸、播放特效）
  * 由 ActorFramework 分派給相關 Actor / client

* **ActorFramework**
  * 管一堆 Actor
  * 處理 Command 收發
  * 掃所有 NetVar，挑 dirty 的欄位，encode 成封包
  * 也負責 decode 回來套用

### 🧩 舊架構 Virtual Code（簡化版）

#### NetVar（欄位包裝）

```csharp
public enum NetVarOwnership {
    Server,          // 只有 server 寫
    OwnerRead,       // 只有 owner 讀
    OwnerReadWrite,  // owner 可寫
    ShareRead,       // share 讀
    ShareReadWrite   // share 可寫
}

public class NetVar<T> {
    public T Value;
    public NetVarOwnership Ownership;
    public bool IsDirty;
    public bool IsUpdated;

    public void Set(T newValue) {
        if (!Equals(Value, newValue)) {
            Value = newValue;
            IsDirty = true;
        }
    }
}
```

#### Actor（物件＋狀態＋行為）

```csharp
public abstract class Actor {
    protected Dictionary<string, INetVar> _netvars = new();

    protected void RegisterVar(string name, INetVar var) {
        _netvars[name] = var;
    }

    public virtual void OnCommand(ActorCommand cmd) {
        // 預設由子類 override 處理
    }

    public virtual void Tick(float dt) {
        // 遊戲邏輯
    }
}
```

#### ActorFramework（掃 NetVar 同步）

```csharp
public class ActorFramework {
    List<Actor> _actors;

    public void Tick(float dt) {
        foreach (var actor in _actors)
            actor.Tick(dt);

        // 🔥 同步：掃 NetVar，算給每個 client 的更新指令
        foreach (var client in _clients) {
            var cmd = CreateUpdateCommandForClient(client);
            if (cmd != null)
                SendToClient(client, cmd);
        }
    }

    private ActorCommand CreateUpdateCommandForClient(Client c) {
        var cmd = new ActorCommand();
        foreach (var actor in _actors) {
            foreach (var var in actor.NetVars) {
                if (ShouldSyncToClient(var, c) && var.IsDirty) {
                    cmd.AddVar(actor.Id, var.Name, var.Value);
                }
            }
        }
        return cmd;
    }
}
```

**重點痛點：**

* NetVar 同時扛「可見度 + 寫入權限 + dirty flag」
* 同一份 NetVar 被：
  * 遊戲邏輯改
  * 同步邏輯讀 & 清 `IsDirty`
* 想多執行緒會變成：**更新執行緒 vs 同步執行緒搶同一份狀態**
* client 有時也能寫（OwnerReadWrite） → 更複雜

---

## 2️⃣ 新框架：StateTree + SyncPolicy + Realm + Action

### 🌳 新概念對應

* **StateTree**
  * 純 struct，描述世界狀態
  * 每個欄位附上一個 `@Sync(...)` 作為**欄位級同步策略**
  * 不再承擔「誰能寫」，只管「怎麼被同步」

* **SyncPolicy**
  * `.broadcast`、`.perPlayerSlice`、`.perRole`、`.serverOnly`…
  * 決定每個欄位在不同 client 視角下要怎麼被切／被隱藏

* **Realm**
  * 一個 StateTree 的**實體世界（樂園）**
  * 決定誰能進來、可以做什麼、Tick、Lifetime、持久化
  * server 在這裡 **唯一有權改 state**

* **Action（Command 的進化版）**
  * client 發意圖：`move`, `attack`, `sendChat`…
  * Realm 收到 → 改 StateTree → sync engine 自動算 diff

* **Sync Engine**
  * 在每個 tick 後拿一份 StateTree snapshot
  * 依 SyncPolicy + ctx(playerID, role) 為每個 client 算 view + diff

### 🧩 新架構 Virtual Code（對應版本）

#### StateTree（取代 Actor + NetVar）

```swift
@StateTreeBuilder
struct PlayerState: StateTreeProtocol {
    @Sync(.broadcast)
    var name: String

    @Sync(.perPlayer)   // 只有自己看到
    var inventory: [Item]

    @Sync(.serverOnly)
    var gmTag: String
}

@StateTreeBuilder
struct RoomState: StateTreeProtocol {
    @Sync(.broadcast)
    var title: String

    @Sync(.broadcast)
    var players: [PlayerID: PlayerState]

    @Sync(.perRole(.teacher))
    var allStudentStates: [PlayerID: PlayerState]
}
```

* 舊的 `NetVarOwnership` → 變成每個欄位的 `@Sync(...)`
* `IsDirty` 那種 flag → 由 StateTree 引擎內部管理，不再暴露在 model 上

---

#### Realm（取代 ActorFramework + Room 管理）

```swift
@Realm(RoomState.self)
struct RoomRealm {
    // 1. 誰可以進來這個世界
    AccessControl {
        AllowPublic()
        MaxPlayers(10)
    }

    // 2. 玩家進出時如何修改 StateTree
    OnJoin { state, ctx in
        state.players[ctx.playerID] = PlayerState(name: "Guest")
    }

    OnLeave { state, ctx in
        state.players.removeValue(forKey: ctx.playerID)
    }

    // 3. 可以對這個世界做哪些操作（Action）
    Action("move") { state, action, ctx in
        state.players[ctx.playerID]?.position = action.position
    }
    
    Action("attack") { state, action, ctx in
        // 改 HP、加特效旗標等等
    }

    // 4. 世界的營業時間 / Tick
    Lifetime {
        Tick(every: .milliseconds(50)) { state, ctx in
            // 每幀更新 buff / 冷卻 / 計時器...
        }

        DestroyWhenEmpty(after: .minutes(5))
        PersistSnapshot(every: .seconds(30))
    }
}
```

---

### ⚙️ 多執行緒同步：Virtual Code

#### Phase A：單執行緒更新 StateTree（像舊的 game loop）

```swift
actor RealmRunner {
    var state: RoomState
    var clients: [Client]

    func tick(dt: TimeInterval) async {
        // 1. 處理 Action（意圖）
        applyPendingActions()

        // 2. 執行 Tick 邏輯
        updateGameLogic(dt)

        // 3. 同步給所有 client
        await syncAllClients()
    }
}
```

#### Phase B：snapshot + 並行算「每個人的視角」

```swift
extension RealmRunner {
    func syncAllClients() async {
        let snapshot = state   // RoomState 是 struct，這裡是值語意 copy

        await withTaskGroup(of: Void.self) { group in
            for client in clients {
                group.addTask {
                    await self.syncOneClient(client, snapshot: snapshot)
                }
            }
        }
    }

    func syncOneClient(_ client: Client, snapshot: RoomState) async {
        // 套用 SyncPolicy 計算「這個 client 的 view」
        let view = computeView(for: client, from: snapshot)

        // 和上一次 view 做 diff
        let diff = diffEngine.diff(old: client.lastView, new: view)

        if !diff.isEmpty {
            sendPatch(to: client, patch: diff)
            client.lastView = view
        }
    }
}
```

**關鍵點：**

* `snapshot` 是那一幀的「定格狀態」，之後**只讀不寫**
* `computeView` / `diff` 都是純函數
* 可以用 TaskGroup / ThreadPool **平行跑**每個 client 的視角計算

和舊的：

* 同一份 NetVar 又被邏輯改、又被同步程式讀＋清 dirty
  完全不同等級的好切割。

---

## 3️⃣ 綜合對照表（舊概念＋新概念＋多執行緒）

### 《Actor / NetVar 世界 vs StateTree / Realm 世界》

| 類別 | 舊世界：Actor / NetVar / Framework | 新世界：StateTree / SyncPolicy / Realm | 說明 |
| :--- | :--- | :--- | :--- |
| **「狀態」的基本單位** | `Actor`：一個物件，裡面一堆 `NetVar` | `StateTree`：一組純 struct（`RoomState`, `PlayerState`） | Actor 變成單純資料模型 |
| **欄位封裝** | `NetVar<T>`：Value + Ownership + DirtyFlag | `var foo: T` + `@Sync(...)` metadata | 欄位本身乾淨，metadata 負責同步策略 |
| **欄位同步語意** | `ENetVarOwnership` 混合「誰能讀／寫／同步」 | `SyncPolicy`（`.broadcast`, `.perPlayerSlice`, `.perRole`, `.serverOnly`）只管「誰看得到」 | 寫入權利搬走，統一交給 server |
| **權威寫入者** | Actor / NetVar 支援 owner write / share write → client 也可能改 | **只有 server（Realm）改 StateTree**，client 僅發 Action | 減少同步衝突、避免作弊 |
| **操作（行為）** | `Actor.OnCommand(...)`、`Actor.Tick(...)`，行為綁在 Actor 類別上 | `Action("xxx") { state, action, ctx in ... }` + Realm 的 Tick block | 行為拆成 Action + Realm DSL，StateTree 保持資料模型 |
| **同步管線** | ActorFramework 掃所有 Actor.NetVar，判斷 IsDirty + Ownership，組成更新 Command | SyncEngine 走整棵 StateTree + SyncPolicy + ctx，算出每個 client 的 view，再 diff | 差異計算與可見度一體化 |
| **客製視角** | `StateView` / 手動決定哪些 Actor / NetVar 要加進封包 | SyncPolicy per-field + 自動 per-connection filter（perPlayer/perRole 等） | 不再手動 add/remove node，改成宣告式 policy |
| **房間／世界管理** | ActorFramework + Room 邏輯散在多處 | `Realm<RoomState>`：AccessControl / OnJoin / OnLeave / Action / Tick / Lifetime / Persist | Realm 正式變成「世界樂園容器」 |
| **事件／廣播** | `ActorEvent` + Framework 廣播給相關 Actor / client | 一部分用 StateTree 欄位（例如 `@Sync(.broadcast)` 的 `events` queue），或額外定義 event stream | 可直接投影成狀態的一部分 |
| **多執行緒：更新** | 遊戲邏輯與同步邏輯都觸碰同一份 NetVar（Value + DirtyFlag），要鎖很醜 | Realm（可用 Swift actor）單執行緒更新 StateTree，這一階段不考慮同步 | 更新階段像傳統 game loop，簡單穩定 |
| **多執行緒：同步** | 同步程式也要改 NetVar 狀態（清 Dirty / Updated），很難安全平行化 | Tick 後拿一份 `RoomState` snapshot（struct 值），用多 Task/Thread 並行算各 client 的 view + diff，只讀、不改 snapshot | 自然形成「單寫入、多讀取」，非常適合並行化 |
| **適用範圍** | 主要針對「線上遊戲伺服器」（高度客製） | 適用遊戲、教學平台、即時電商、協作白板、任何「多人共用狀態」場景 | 抽象層從「遊戲專用」提升到「通用狀態同步引擎」 |
| **開發體驗** | 手寫 NetVar / Ownership / encode/decode / Command 分派 | Swift DSL：`@StateTreeBuilder` + `@Sync` + Realm DSL，型別安全、IDE 友善、結構清楚 | 更接近 SwiftUI / SwiftData 的開發模式 |
