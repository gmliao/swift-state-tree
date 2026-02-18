# Package 拆解評估：對照 Infra 設計文件

> **設計文件參考**：`docs/plans/2026-02-12-matchmaking-control-plane-design.md` 定義 Package Layout：
> - `MatchmakingContracts`：DTOs、error codes、protocol contracts
> - `MatchmakingCore`：strategy、queueing、dedupe、assignment lifecycle
> - `MatchmakingInfraRedis`：Redis adapter
> - `MatchmakingAPI`：HTTP/gRPC entry

---

## 0. 底層共用模組（依設計文件整理）

設計文件將「共用層」與「領域層」分開。以下對照設計文件的 Package Layout，整理 control-plane 的底層共用模組：

### 0.1 設計文件 Package Layout → 現況對照

| 設計文件 Package | 職責 | 現況 control-plane | 建議目錄 |
|-----------------|------|-------------------|----------|
| **MatchmakingContracts** | DTOs、error codes、protocol | `contracts/` | `src/contracts/` |
| **MatchmakingInfraRedis** | Redis adapter | `matchmaking/storage/redis-*`、`pubsub/redis-*` | `src/infra/redis/` 或保持分散 |
| **Pub/Sub 抽象** | 通知通道（設計文件 Storage Strategy） | `pubsub/` | `src/pubsub/` |
| **Security** | JWT、JWKS | `security/` | `src/security/` |
| **BullMQ** | Job queue 配置 | `bullmq/` | `src/bullmq/` |

### 0.2 底層共用模組結構（建議）

```
src/
  # === 底層共用（設計文件對應） ===
  contracts/           # MatchmakingContracts：DTOs、error codes、protocol
    assignment.dto.ts
    matchmaking.dto.ts
    http-status.ts
    error-codes.ts
  pubsub/              # Pub/Sub 抽象：channel 介面、Redis/InMemory 實作
    match-assigned-channel.interface.ts
    channels.ts
    redis-match-assigned-channel.service.ts
    inmemory-match-assigned-channel.service.ts
  security/            # JWT、JWKS
  bullmq/              # Job queue 配置

  # === 領域模組（依賴底層） ===
  matchmaking/         # MatchmakingCore + API
  provisioning/        # Provisioning client、registry
  realtime/            # Gateway（WebSocket）
```

### 0.3 依賴關係（底層 → 領域）

```
contracts     ← matchmaking, provisioning, realtime, pubsub
pubsub        ← matchmaking (publish), realtime (subscribe)
security      ← matchmaking (JWT)
bullmq        ← matchmaking (EnqueueTicketProcessor)
```

### 0.4 待整理項目

| 項目 | 現況 | 建議 |
|------|------|------|
| **Provisioning DTOs** | `provisioning/dto/` | 可併入 `contracts/` 或保持 `contracts/provisioning/` 子目錄 |
| **Redis 實作** | 分散在 matchmaking/storage、pubsub | 可選：抽成 `infra/redis/` 統一 Redis 連線；或保持各模組內 |
| **ws-envelope.dto** | `realtime/ws-envelope.dto.ts` | 屬 Gateway 協議，可移入 `contracts/` 作為共用 |

---

## 1. 現況 vs 設計文件對照

| 設計文件組件 | 現況 control-plane | 差距 |
|-------------|-------------------|------|
| **Gateway** | `realtime/` (RealtimeGateway) | 缺：userId→sockets registry、node inbox 訂閱、ClusterDirectory 註冊 |
| **ClusterDirectory** | 無 | 全新組件，需實作 |
| **GatewayBroker** | `pubsub/` (MatchAssignedChannel, broadcast) | 現為 broadcast；設計為 **node inbox**（`cd:inbox:{nodeId}`） |
| **Matchmaking** | `matchmaking/` | 已有 ticket、match、provision；缺 sendToUser 路由 |
| **Provisioning** | `provisioning/` | 已有 HTTP client；缺 BullMQ job 觸發、補償 |
| **JobSystem** | `bullmq/` + EnqueueTicketProcessor | 已有 enqueue job；缺 provision job、dispatch-worker |
| **Dispatch Worker** | 無 | 需新增（provision job、sendToUser 發送） |

---

## 2. 架構差異重點

### 2.1 投遞模式

| | 現況 | 設計文件 |
|---|------|----------|
| **MatchFound 投遞** | `matchmaking:assigned` broadcast，所有 API 訂閱，各自檢查 ticketSubscriptions | `cd:inbox:{nodeId}` 定向投遞，先查 userId→nodeId，再 publish 到該 node |
| **路由** | 無（ticketId 對應 client，client 連到哪個 API 不透明） | ClusterDirectory：userId→nodeId(s)，TTL lease |
| **適用場景** | ticketId 訂閱（client 先連 WS 再 enqueue） | userId 定向（sendToUser、Invite、QueueStatus） |

### 2.2 關鍵結論

- **現況**：以 **ticketId** 為 key，client 連到某 API 後訂閱該 ticket，match 完成時 broadcast，有該 ticket 的 API 才 push。
- **設計文件**：以 **userId** 為 key，ClusterDirectory 記錄 userId 在哪個 node，定向 publish 到該 node 的 inbox。

兩者可並存：
- **MatchFound**：可維持 ticketId 訂閱（現有流程），或改為 userId + node inbox（需 ClusterDirectory）。
- **sendToUser / QueueStatus**：必須有 ClusterDirectory + node inbox。

---

## 3. 是否要拆 Package？

### 3.1 建議：**MVP 階段不拆**

| 考量 | 說明 |
|------|------|
| **複雜度** | 拆成多 package 會增加 monorepo、版本、部署、測試複雜度 |
| **MVP 範圍** | 設計文件 MVP 為「必做」清單，現有 control-plane 已涵蓋大部分 |
| **邊界** | 現有 NestJS 模組（matchmaking、realtime、provisioning、bullmq）邊界已清楚 |
| **可抽離性** | 若未來要拆，可依現有模組邊界直接抽成獨立 package |

### 3.2 建議：**單一 package 內模組化**

維持 `Packages/control-plane` 單一 repo，但內部用模組邊界對齊設計文件：

```
Packages/control-plane/src/
  cluster-directory/     # 新增：routing + lease
  gateway/              # 重命名 realtime → gateway，或保持 realtime 但加 gateway 職責
  matchmaking/
  provisioning/
  pubsub/               # 新增：MatchAssignedChannel + 未來 GatewayBroker
  bullmq/
  dispatch/             # 新增：provision job、sendToUser 發送
```

---

## 4. 分階段實施建議

### Phase 1：補齊 Pub/Sub 與 Gateway 整合（現有規劃）

- Pub/Sub：MatchAssignedChannel（Redis + InMemory）
- Gateway：subscribe 並 push
- **不拆 package**

### Phase 2：ClusterDirectory + Node Inbox（對齊設計文件）

- 新增 `cluster-directory/` 模組
- 新增 `cd:user:{userId}`、`cd:lease:user:{userId}:{nodeId}`、`cd:inbox:{nodeId}`
- Gateway：在 connect 時 registerSession、heartbeat refresh
- 將 `matchmaking:assigned` 改為或並存為 node inbox 投遞（需 routing lookup）

> **實作計畫**：`docs/plans/2026-02-15-phase2-cluster-directory-node-inbox.md`

### Phase 3：Provision Job + Dispatch Worker

- Provision 改為 BullMQ job
- 新增 dispatch-worker 或擴充 EnqueueTicketProcessor
- 失敗重試、超時補償

### Phase 4：評估是否拆 Package

- 若需獨立部署、不同團隊維護、不同 scaling 策略，再拆成：
  - `cluster-directory`（lib）
  - `gateway`（service）
  - `matchmaking-service`
  - `provisioning-service`
  - `dispatch-worker`

---

## 5. 總結

| 問題 | 建議 |
|------|------|
| **現在要拆 package 嗎？** | 否，維持單一 control-plane |
| **要對齊設計文件嗎？** | 是，分階段在模組層級對齊 |
| **優先順序** | 1) Pub/Sub 整合 2) ClusterDirectory 3) Node Inbox 4) Provision Job 5) 視需求再拆 package |

---

## 6. 模組拆解的價值分析

### 6.1 拆模組的價值

| 價值 | 說明 |
|------|------|
| **單一職責** | 每個模組只做一件事，邊界清楚，改動影響範圍小 |
| **可測試性** | 可 mock 依賴、單獨測模組，不需起整包 |
| **可抽離** | 未來若要拆 package，模組邊界即抽離邊界 |
| **依賴可視** | import 關係明確，易發現 circular dependency |
| **認知負擔** | 新人可依模組理解系統，不用一次看全貌 |
| **並行開發** | 不同模組可不同人維護，減少衝突 |

### 6.2 各模組拆解價值評估

| 模組 | 價值 | 理由 |
|------|------|------|
| **pubsub/** | 高 | 抽離 transport，Matchmaking 不直接依賴 Redis；可換 InMemory 測；未來 node inbox、其他 channel 可共用 |
| **cluster-directory/** | 高 | 獨立 routing 職責；Gateway、Matchmaking、Dispatch 都會用；可單獨測 routing 邏輯 |
| **dispatch/** | 中高 | 分離「發送」與「配對」；Matchmaking 只產事件，Dispatch 負責投遞；未來 sendToUser、provision job 集中 |
| **contracts/** | 中 | 已存在；可再細分 contracts/matchmaking、contracts/provisioning，降低跨模組 DTO 耦合 |
| **matchmaking/storage** | 中 | 可抽成 matchmaking-storage 子模組或獨立模組；store 與 queue 邏輯分離 |
| **realtime → gateway** | 低 | 重命名對齊設計；若加 inbox、registry，職責變多，模組邊界更清楚 |

### 6.3 建議模組結構（盡量拆）

```
src/
  cluster-directory/       # 新增：routing + lease（Phase 2）
  pubsub/                 # 新增：MatchAssignedChannel、未來 NodeInbox（Phase 1）
  gateway/                # 重命名 realtime：WS + registry + inbox 訂閱
  matchmaking/            # 精簡：只保留 ticket、match、strategy
    storage/              # 子模組：queue、store
  provisioning/           # 保持
  dispatch/               # 新增：job 發送、sendToUser（Phase 3）
  bullmq/                 # 保持
  security/               # 保持
  contracts/              # 保持，可選細分
```

### 6.4 拆解優先順序

| 順序 | 動作 | 價值/成本 |
|------|------|-----------|
| 0 | **整理底層共用模組**（contracts、pubsub、security、bullmq） | 對齊設計文件，釐清依賴 |
| 1 | 抽 **pubsub**（MatchAssignedChannel） | ✅ 已完成 |
| 2 | Gateway 整合 pubsub subscribe | ✅ 已完成 |
| 3 | 新增 **cluster-directory** | 高價值，為 node inbox 鋪路 |
| 4 | 新增 **dispatch** | 中高價值，集中投遞邏輯 |
| 5 | realtime → gateway 重命名 | 低成本，對齊命名 |
| 6 | matchmaking/storage 細分 | 可選，依複雜度決定 |

### 6.5 不建議過度拆的項目

- **contracts** 細分過細：DTO 通常跨模組共用，拆太碎反而 import 路徑變長
- **bullmq** 再拆：目前只做 config，保持即可
- **security** 再拆：JWT 職責單一，維持現狀

---

## 7. 附錄：設計文件建議的 Repo 結構 vs 建議

```
# 設計文件 Package Layout (2026-02-12-matchmaking-control-plane-design.md)
MatchmakingContracts/    → DTOs, error codes, protocol
MatchmakingCore/        → strategy, queueing, dedupe
MatchmakingInfraRedis/  → Redis adapter
MatchmakingAPI/         → HTTP/gRPC entry

# 建議 MVP 結構（單一 package，底層共用 + 領域模組）
Packages/control-plane/src/
  # 底層共用（對應設計文件）
  contracts/            # MatchmakingContracts
  pubsub/               # Pub/Sub 抽象（MatchmakingInfraRedis 的 channel 部分）
  security/             # JWT、JWKS
  bullmq/               # Job queue 配置

  # 領域模組
  cluster-directory/    # 新增（Phase 2）
  gateway/              # 重命名 realtime
  matchmaking/          # MatchmakingCore + API
  provisioning/
  dispatch/             # 新增（Phase 3）
```
