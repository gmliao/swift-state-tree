# Matchmaking MVP 設計分析：湊滿一組通知

**日期**: 2026-02-15  
**對照**: 最終版本（MVP，湊滿一組通知）設計稿

---

## 一、設計摘要

| 維度 | 新設計 | 現有實作 |
|------|--------|----------|
| **配對模型** | 湊滿 N 人成組 | 每 ticket 獨立分配 |
| **Worker** | 單一 matchmaker，本地 Map | Tick + 多 Worker 可擴展 |
| **儲存** | BullMQ job + 本地記憶體 | BullMQ job + Redis metadata |
| **觸發** | enqueueTicket job 驅動 | 定時 tick |
| **通知** | Pub/Sub → API 推 ticket room | 同 process 直接推 |

---

## 二、優點

| 項目 | 說明 |
|------|------|
| **職責清晰** | API 只管 WS/REST，Worker 只管配對 |
| **Group 概念** | groupId、members 明確，利於補領與除錯 |
| **ROLE 分離** | `ROLE=api` / `ROLE=matchmaker` 易於 K8s 部署 |
| **升級路徑** | 文檔明確定義何時升級到 Redis Lua + 多 worker |
| **協議精簡** | 4 個事件：request, queued, assigned, poll |
| **補領機制** | match:result → groupId → group 流程清楚 |

---

## 三、風險與待釐清

### 3.1 Worker 重啟導致 in-flight 遺失

**問題**：Worker 用本地 `Map<queueKey, TicketQueue>`。消費 `enqueueTicket` 後 job 即完成，ticket 只存在記憶體。Worker 重啟時，尚未湊滿的 ticket 會遺失。

**決策**：接受 MVP 限制，並在文件註明。

### 3.2 Party / 隊列參數（min、max、等待時間）

**決策**：queueKey 對應的隊列可設定：

| 參數 | 說明 | 範例 |
|------|------|------|
| `minGroupSize` | 最少幾人可成組 | 1（solo 一人即可開） |
| `maxGroupSize` | 最多幾人成組 | 3（3v3） |
| `minWaitMs` | 最少等待時間 | 可選 |
| `relaxAfterMs` | 超過後放寬條件 | 可選 |

**範例**：
- Solo 模式：`minGroupSize=1, maxGroupSize=1` → 一人即可 assigned
- 3v3 模式：`minGroupSize=3, maxGroupSize=3` → 湊滿 3 人
- 彈性模式：`minGroupSize=2, maxGroupSize=4` → 2～4 人皆可（依 relaxAfterMs 放寬）

參數來源：queueKey 解析（如 `hero-defense:3v3`）或設定檔對應。

### 3.3 Provisioning 與 JWT

**決策**：一組 N 人共用一個 room，每人需要自己的 matchToken（JWT）。

**實作**：
- `allocate` 改為接受 `members: [{ ticketId, userId }]`，回傳一個 landId/connectUrl
- 對每個 member 各發一張 JWT（同一 landId，不同 playerId/jti）

### 3.4 Redis Pub/Sub 與多 API 實例

**決策**：使用 Redis Pub/Sub，所有 API 訂閱同一 channel，收到後各自檢查本地 socket 再推送。

**流程**：

1. **Worker 湊滿後**：`PUBLISH match.group.assigned { groupId }`（只發 groupId）

2. **每台 API 訂閱**：`SUBSCRIBE match.group.assigned`

3. **收到訊息後**（每台都收到同一則）：
   - 讀 `match:group:{groupId}` 取得完整 group（含 members、assignment）
   - 對每個 `member.ticketId` 檢查：**本機是否有該 ticket 的 socket？**
   - 有 → push；無 → 略過（該 player 連在別台 API）

4. **範例**（3 人成組、3 台 API）：
   | API 實例 | 本機 socket | 動作 |
   |----------|-------------|------|
   | API-1 | t_123 | 只 push 給 t_123 |
   | API-2 | t_124 | 只 push 給 t_124 |
   | API-3 | t_125 | 只 push 給 t_125 |

**重點**：訊息只含 groupId；完整資料在 `match:group:{groupId}`；每台 API 對 group 內所有 ticketId 逐一檢查本機 socket，只 push 給連在自己這台的 client。

### 3.5 jobId = ticketId 的時序

**問題**：API 產生 ticketId 後才 `Queue.add(..., { jobId: ticketId })`。若 ticketId 碰撞（機率低）或重試，BullMQ 會拒絕。需確保 ticketId 全域唯一（如 UUID）。

---

## 四、與現有架構的對應

| 現有元件 | 新設計對應 | 變更幅度 |
|----------|------------|----------|
| MatchmakingController | 保留，改為 emit match.queued | 小 |
| MatchQueuePort / BullMQMatchQueue | 改為 enqueueTicket job，不再用 matchmaking-tickets | 大 |
| MatchStrategyPort | 改為「湊滿 min～max」邏輯（含 relaxAfterMs），在 Worker 內 | 中 |
| RealtimeGateway | 需支援 Pub/Sub 訂閱，或改為 API 訂閱後轉發 | 中 |
| ProvisioningClientPort | allocate 改為接受 group，回傳一房 | 中 |
| JwtIssuerService | 需支援一次 issue N 張（同 landId） | 小 |

---

## 五、資料流對照

### 現有

```
enqueue → MatchQueuePort.enqueue (BullMQ job)
tick job → listQueuedByQueue → strategy.findMatchableTickets
       → 逐 ticket processMatch → updateAssignment → pushMatchAssigned
```

### 新設計

```
match.request → Queue.add(enqueueTicket) → 回 match.queued
Worker 消費 → 加入 Map → 湊滿 N → 寫 match:group、match:result → PUBLISH match.group.assigned { groupId }
每台 API 訂閱 → 收到 groupId → 讀 match:group:{groupId} → 對每個 member.ticketId 檢查本機 socket → 有則 push
```

---

## 六、落地建議

### 6.1 分階段

| 階段 | 範圍 | 說明 |
|------|------|------|
| **Phase 1** | 單 process，先不拆 ROLE | API + Worker 同 process，驗證湊滿邏輯 |
| **Phase 2** | ROLE 分離 | 用 env 分 api / matchmaker |
| **Phase 3** | 多 API + Pub/Sub | 訂閱、推送、補領 |

### 6.2 已定案

- **多 instance 推送**：Redis Pub/Sub，每台 API 訂閱後各自檢查本地 socket 再 push（見 3.4）

### 6.3 最小可行調整

若希望改動最小、先驗證「湊滿」：

- 保留現有 MatchQueuePort（BullMQ tickets）
- 僅改 MatchStrategyPort：`findMatchableGroups(queued, minGroupSize, maxGroupSize, relaxAfterMs)` 回傳「可湊滿的 ticket 組」
- MatchmakingService：一次處理一組，呼叫 allocate(group)，對每 ticket 各 issue JWT
- 通知仍用現有 RealtimeGateway（單 instance）

這樣可先驗證湊滿與 provisioning，再逐步引入 ROLE、Pub/Sub、多 instance。

---

## 七、結論

| 維度 | 評價 |
|------|------|
| **目標對齊** | 清楚：MVP、湊滿、可擴展、可升級 |
| **架構** | 簡潔，職責分離好 |
| **可落地性** | 高，Party、重啟、Redis Pub/Sub 多 instance 推送均已定案 |
| **與現有整合** | 需調整 Queue、Strategy、Provisioning、Gateway |

**建議**：Party 參數（min/max、等待時間）與 Provisioning/JWT 已定案；可先用「最小可行調整」在現有架構上驗證湊滿邏輯，再拆 ROLE 與多 instance。
