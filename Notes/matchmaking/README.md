# Matchmaking

> **注意 (2026-02)**：Swift 內建配對模組（SwiftStateTreeMatchmaking）已歸檔。配對現由 **NestJS control plane** 處理。

## 現行架構

配對採用 **雙平面架構**（Control Plane + Runtime Plane）：

- **Control Plane**：NestJS（`Packages/control-plane`）
  - 玩家 enqueue / poll
  - 分配 connectUrl（GameServer WebSocket URL）
  - Provisioning API：GameServer 啟動時註冊

- **Runtime Plane**：Swift GameServer
  - 透過 `SwiftStateTreeNIOProvisioning` 向 control plane 註冊
  - 接收 client 連線（connectUrl 由 control plane 提供）

## 相關文檔

- **[Matchmaking Two-Plane Architecture](../../docs/matchmaking-two-plane.md)** - 架構說明、client 流程、connectUrl
- **[Matchmaking Local Dev Stack](../../docs/operations/matchmaking-local-dev-stack.md)** - 本地開發環境
- **[Provisioning API Contract](../../docs/contracts/provisioning-api.md)** - Provisioning API 規格

## 歸檔參考

舊版 Swift 內建配對（MatchmakingService、LobbyContainer、DefaultMatchmakingStrategy）已移至 `Archive/SwiftStateTreeMatchmaking/`，僅供參考。
