
---

# LAND DSL 房間生命週期規格 v1.1（含 async 版）

> 本文件說明 Land DSL 中房間（Room）的生命週期行為、Hook 呼叫順序與責任分界。  
> v1.1 將 Hook 全面升級為支援 `async/await`，以便整合 DB、Redis、外部服務等 I/O。

---

## 1. 設計目標

- 定義玩家與房間互動的完整生命週期（Join / Leave / Tick / Event）。
- 明確切分：
  - 傳輸層（Transport / Gateway）
  - 權威狀態層（LandKeeper / Room 核心）
  - 業務邏輯層（Room DSL Hook）
- 提供型別安全、可預測、可測試的 Hook 介面。
- 支援 `async/await`，讓 Hook 能安全存取外部資源。

---

## 2. 整體流程總覽

玩家加入房間的主流程：

1. **Client** 發送「加入房間」請求（`joinRoom`）。
2. **Transport / Gateway** 驗證：
   - token / session
   - 版本 / 裝置資訊
   - 黑名單 / 封鎖等
3. 驗證通過後將 `JoinRequest(session, roomId)` 送至 **LandKeeper**。
4. **LandKeeper** 選定目標房間實例（Room instance）。
5. 呼叫 Room DSL 的 `CanJoin(state, session, ctx)`（`async throws`）：
   - 若允許 → 生成 `JoinDecision.allow(playerID: ...)`
   - 若拒絕 → 丟出 `JoinError` 或回傳 deny
6. 若允許：
   - Land 核心將玩家加入 `RoomState`（權威狀態）。
   - 之後呼叫 `OnJoin(state, player, ctx)`（`async`）。
   - 計算 diff / 初始狀態，回傳給 Client。
7. 若拒絕：
   - 不修改 `RoomState`。
   - 將失敗原因（可選）回傳給 Client。

玩家離開房間的主流程：

- 由以下任一事件引發：
  - Client 主動發出「離開房間」請求。
  - 連線關閉 / 心跳逾時。
  - 管理者 / 系統踢出玩家。
- Land 核心決定要移除該玩家：
  1. 呼叫 `OnLeave(state, player, ctx)`（`async`）。
  2. 從 `RoomState` 中移除玩家。
  3. 廣播玩家離開訊息 / diff 給其他玩家。

---

## 3. 加入房間 Sequence Diagram（含 async）

```mermaid
sequenceDiagram
    participant C as Client
    participant G as Transport
    participant L as LandKeeper
    participant R as Room(DSL)

    C->>G: joinRoom(roomId)
    G->>G: 驗證 token / 版本 / banlist
    alt 認證失敗
        G-->>C: JoinFailed(authError)
    else 認證成功
        G->>L: JoinRequest(session, roomId)
        L->>R: CanJoin(state, session, ctx) (async)
        alt CanJoin = allow
            R-->>L: JoinDecision.allow(playerId)
            L->>L: state.addPlayer(playerId)
            L->>R: OnJoin(state, player, ctx) (async)
            R-->>L: OK
            L-->>C: JoinSuccess(initial diff)
        else CanJoin = deny / throws
            R-->>L: JoinDecision.deny(reason) / JoinError
            L-->>C: JoinFailed(reason)
        end
    end
````

---

## 4. Hook 一覽表（生命週期向）

| Hook 名稱                  | 呼叫時機                             | async/throws       | 允許修改 state | 主要用途                         |
| ------------------------ | -------------------------------- | ------------------ | ---------- | ---------------------------- |
| `Config { ... }`         | 房型註冊 / 初始化                       | sync               | ✅          | 設定 `MaxPlayers`、`MinLevel` 等 |
| `CanJoin { ... }`        | **玩家加入前**，尚未寫入 RoomState         | `async throws`     | ❌（只讀）      | 判斷是否允許加入房間                   |
| `OnJoin { ... }`         | 已通過 `CanJoin` 且核心已加入 RoomState 後 | `async`（不 throws）  | ✅          | 初始化玩家狀態、廣播入場訊息               |
| `OnLeave { ... }`        | 玩家即將被移出 RoomState 時              | `async`            | ✅          | 清理狀態、廣播離場訊息                  |
| `On(ClientEvents) {}`    | 收到客戶端事件時                         | `async`（可 throws?） | ✅          | 處理遊戲指令（移動、攻擊…）               |
| `OnTick(every:) { ... }` | 伺服器定期 Tick 時（例如 50ms / 100ms）    | 建議 sync            | ✅          | 遊戲迭代、AI、物理模擬                 |

> 詳細 async 行為、錯誤處理與執行模型，請見 `LAND-DSL-AsyncModel.md`。

---

## 5. DSL 使用範例（含 async Hook）

以下為 `BattleRoom` 的完整房型範例，展示常見 Hook ：

```swift
Land("BattleRoom") {

    // 房間設定（同步）
    Config {
        MaxPlayers(8)
        MinLevel(5)
    }

    // 判斷玩家是否可以加入房間（async + throws）
    CanJoin { state, session, ctx async throws in
        // 1. 檢查房間人數
        guard state.players.count < state.maxPlayers else {
            throw JoinError.roomIsFull
        }

        // 2. 查詢玩家資料（例如從 UserService / DB）
        let profile = try await ctx.userService.loadProfile(id: session.playerID)

        guard profile.level >= state.minLevel else {
            throw JoinError.levelTooLow(required: state.minLevel)
        }

        // 3. 檢查是否被封鎖
        if state.banned.contains(profile.id) {
            throw JoinError.banned
        }

        // 通過：決定此玩家在房間中的 PlayerID
        return .allow(playerID: PlayerID(profile.id))
    }

    // 玩家真正加入後（權威狀態已寫入）
    OnJoin { state, player, ctx async in
        state.players[player.id] = PlayerState(
            name: player.name,
            hp: 100,
            position: .spawnPoint
        )

        await ctx.metrics.increment("room.join")
        ctx.broadcast(.systemMessage("\(player.name) 加入戰場"))
    }

    // 玩家離開（主動離開 / 斷線 / 被踢）
    OnLeave { state, player, ctx async in
        state.players.removeValue(forKey: player.id)
        await ctx.metrics.increment("room.leave")
        ctx.broadcast(.systemMessage("\(player.name) 離開戰場"))
    }

    // 一般事件處理（移動、攻擊等）
    On(ClientEvents.self) { state, event, ctx async in
        switch event {
        case .move(let dir):
            state.movePlayer(id: ctx.playerID, direction: dir)

        case .attack(let targetID):
            state.attack(attacker: ctx.playerID, target: targetID)
            await ctx.battleLog.append(
                .attack(from: ctx.playerID, to: targetID)
            )
        }
    }

    // Tick：建議保持同步，以確保節奏穩定
    OnTick(every: .milliseconds(50)) { state, ctx in
        state.stepSimulation()

        // 若有需要 async 的事情，用背景任務處理
        ctx.spawn {
            await ctx.flushMetricsIfNeeded()
        }
    }
}
```

---

## 6. 責任邊界整理

### 6.1 Transport / Gateway 層

負責：

* Token / Session 驗證
* 版本檢查
* 基本封鎖（IP / 裝置級黑名單）
* 將已驗證的 `session` 與 `joinRoom` 請求送往 LandKeeper

不負責：

* 房間是否已滿
* 玩家等級是否符合此房間
* 遊戲內規則相關的允入判斷

### 6.2 LandKeeper / Room 核心

負責：

* 管理 Room 實例生命週期
* 依照房型（Land 定義）建立、銷毀 Room
* 呼叫 Room DSL Hook（`CanJoin / OnJoin / OnLeave / OnTick / OnEvent`）
* 維護權威狀態（RoomState）

### 6.3 Room DSL（Land 定義）

負責：

* 房間內的遊戲規則：

  * 玩家什麼時候能進、不能進
  * 進來之後要建立什麼狀態
  * 離開時要清掉什麼東西
  * 指令如何影響狀態
  * Tick 如何推進遊戲

不負責：

* 連線層安全（token 驗證）
* 全系統級的 Matchmaking 決策（可以由外部服務選好房間再呼叫 join）

---

## 7. 未來擴充方向

* `CanSpectate`：支援觀戰模式（允許加入但不列入玩家清單）。
* Matchmaking 整合：由外部 Matchmaking Service 決定房型與房間，再進入 Land Join 流程。
* Room Persistence：

  * 房間狀態快照（snapshot）
  * 伺服器重啟後恢復 Room 狀態
* 生命週期事件：

  * `OnRoomCreated`
  * `OnRoomClosed`
  * `OnAllPlayersLeft`（可用來自動關房）

---

## 8. 版本說明

* v1.0：初版生命週期規格（未明確定義 async）。
* v1.1：

  * 將 `CanJoin` 定義為 `async throws`。
  * 將 `OnJoin / OnLeave / On(ClientEvents)` 升級為 `async`。
  * 建議 `OnTick` 維持同步邏輯，本身不直接 `await` 遠端；
    如需 async，使用 `ctx.spawn` 類 API。

詳細 async / Actor / 執行順序說明，請參考
**`LAND-DSL-AsyncModel.md`**。

````

---

## 📙 檔案二：`LAND-DSL-AsyncModel.md`

```markdown
# LAND DSL Async 模型與執行順序規格 v1.0

> 本文件聚焦說明 Land DSL 中各 Hook 的 `async/await` 規則、錯誤行為與在 Room/Actor 中的執行順序。

---

## 1. 為什麼需要 async Hook？

實務上，Room 邏輯常常需要：

- 查詢 DB / Redis（玩家資料、道具、封鎖名單）。
- 呼叫其他服務（Matchmaking / Presence / Logging）。
- 寫入外部系統（戰鬥紀錄、成就系統）。

如果 Hook 僅允許同步（sync），  
這些 I/O 就會被迫塞到：

- Transport 層（變成 spaghetti）
- 外部 Manager（邏輯分散）
- 或用 blocking I/O（毀掉整體延遲）

因此 Land DSL 將以下 Hook 明確定義為 async：

- `CanJoin` → `async throws`
- `OnJoin` / `OnLeave` → `async`
- `On(ClientEvents)` → `async`

---

## 2. 各 Hook 的 async/throws 規則

### 2.1 `Config`

```swift
Config { /* sync */ }
````

* 完全同步。
* 在房型註冊 / Room 初始化時執行。
* 用來設定靜態參數，如：

  * `MaxPlayers`
  * `MinLevel`
  * Tick 間隔（若有）
* 不做任何 I/O。

---

### 2.2 `CanJoin`

```swift
CanJoin { state, session, ctx async throws in
    // ...
}
```

* **呼叫時機**：玩家正式被加入 RoomState 之前。

* **特性**：

  * `async`：允許查 DB / Redis / RPC。
  * `throws`：用於拒絕玩家加入（`JoinError`）。
  * 不允許修改 `state`（視為「只讀視圖」）。

* **語意**：

  ```swift
  typealias CanJoinHandler =
      (RoomState, Session, RoomContext) async throws -> JoinDecision
  ```

* **典型用法**：

  * 檢查房間是否已滿。
  * 查詢玩家等級 / 隊伍狀態。
  * 看玩家是否在黑名單中。
  * 決定此玩家的 `PlayerID`。

---

### 2.3 `OnJoin`

```swift
OnJoin { state, player, ctx async in
    // ...
}
```

* **呼叫時機**：

  * `CanJoin` 已通過（未丟錯）。
  * Land 核心已將該玩家加入 RoomState。

* **特性**：

  * `async`：可以寫 log、呼叫其它服務。
  * 不建議 `throws`，若有錯誤：

    * 框架應當自行捕捉、記錄 Log。
    * 不影響玩家已加入的事實（狀態不可逆）。

* **典型用途**：

  * 初始化 `PlayerState`。
  * 廣播玩家加入訊息。
  * 上報 metrics / presence 狀態。

---

### 2.4 `OnLeave`

```swift
OnLeave { state, player, ctx async in
    // ...
}
```

* **呼叫時機**：

  * 玩家離開房間之前或過程中（離線 / 主動離開 / 被踢）。
  * Land 核心即將從 RoomState 中移除該玩家。

* **特性**：

  * `async`
  * 不建議 `throws`，錯誤同樣應被框架捕捉並 Log。

* **典型用途**：

  * 從 `state.players` 移除玩家。
  * 廣播玩家離開訊息。
  * 更新外部 presence / metrics。

---

### 2.5 `On(ClientEvents.self)`

```swift
On(ClientEvents.self) { state, event, ctx async in
    // ...
}
```

* **呼叫時機**：
  接收到 client 送來的事件（move / attack / chat …）。

* **特性**：

  * `async`：可以做外部 I/O，如記錄戰鬥 log、查詢道具庫存。
  * 是否允許 throws 可由框架設計：

    * 若允許 throws，則需定義錯誤 → 回傳給 Client 的策略。
    * 或改用 Result 型別。

* **建議模式**：

  * 遊戲狀態更新（位置、HP 等）盡量使用同步邏輯。
  * 外部 I/O 以 async 寫在後面（例如 log）。

---

### 2.6 `OnTick(every:)`

```swift
OnTick(every: .milliseconds(50)) { state, ctx in
    // sync
}
```

* **設計原則**：

  * Tick 是房間的「心跳」（遊戲邏輯主迴圈）。
  * 為了確保節奏與延遲穩定，預設為 **同步**（不 async）。
  * 若在 Tick 裡做大量 await，會使行為難以預測。

* **如需 async 行為**，建議：

  ```swift
  OnTick(every: .milliseconds(50)) { state, ctx in
      state.stepSimulation()

      ctx.spawn {
          await ctx.flushMetricsIfNeeded()
      }
  }
  ```

  * `ctx.spawn { ... }` 由框架在背景 Task 中執行。
  * 不阻塞 Tick 主迴圈。

---

## 3. Room Actor 與 async Hook 執行順序

假設每個 Room 由一個 `actor` 管理：

```swift
actor RoomInstance {
    var state: RoomState
    let dsl: RoomDSLHandlers

    // join
    func handleJoin(session: Session) async -> JoinResult {
        // 1. CanJoin
        let decision = try await dsl.canJoin(state, session, context)

        switch decision {
        case .allow(let playerID):
            // 2. 更新權威狀態
            state.addPlayer(playerID)

            // 3. OnJoin（async，但在同一 actor 串行執行）
            await dsl.onJoin(&state, .init(id: playerID), context)

            // 4. 回傳成功 + 初始 diff
            return .success(...)
        case .deny(let reason):
            return .failed(reason)
        }
    }

    // client event
    func handleEvent(from playerID: PlayerID, event: ClientEvent) async {
        await dsl.onEvent(&state, event, context(for: playerID))
    }

    // tick
    func tick() {
        dsl.onTick(&state, context)
    }
}
```

**重點：**

* 所有對 `state` 的操作都在同一個 Room actor 內串行執行，天生避免資料競態。
* async Hook 只是「在 actor 的函式裡，可以 `await` 別的東西」：

  * 不會破壞 state 的一致性。
  * 只是延長這個操作的執行時間。

---

## 4. 錯誤處理策略建議

### 4.1 `CanJoin` 的錯誤處理

* **throws JoinError** → 轉換成 `JoinFailed` 回給 Client。
* 可選擇是否顯示詳細原因給 Client（避免洩漏敏感資訊）。

範例：

```swift
enum JoinError: Error {
    case roomIsFull
    case levelTooLow(required: Int)
    case banned
}

enum JoinResult {
    case success(initialDiff: DiffPayload)
    case failed(reason: PublicJoinErrorReason)
}
```

---

### 4.2 `OnJoin / OnLeave / OnEvent` 的錯誤處理

* 建議：

  * Hook 本身不 throws。
  * 若內部需要 `try`，改用 `do/catch` 自己處理：

    * 記 log
    * 上報 metrics
  * 不讓錯誤影響 Room 主流程。

---

## 5. async 對性能與設計的影響

### 5.1 優點

* 可以自然整合 DB / 外部服務，不需 blocking I/O。
* 可以在 Join 流程中實作複雜條件（等級、配對、封鎖等）。
* Room 仍然保有單執行緒視角（透過 actor），簡化狀態管理。

### 5.2 注意事項

* 避免在 `OnTick` 中做長時間 `await`。
* `CanJoin` 不宜做過慢的操作（例如重度計算），否則玩家感覺會是「進房很卡」。
* 可以搭配 cache / presence service 降低外部查詢頻率。

---

## 6. 小結

* **生命週期負責什麼？** → 見 `LAND-DSL-RoomLifecycle.md`。
* **每個 Hook 能不能 async / 能不能 throws？** → 本文件定義。
* **狀態一致性如何保障？**

  * Room 由 actor 管理。
  * 所有 Hook 對 state 的操作都在 actor 內串行。

---

## 7. 版本說明

* v1.0 初版：針對 Hook async/throws 行為做明確規範，與 v1.1 的 RoomLifecycle 文件對應。

