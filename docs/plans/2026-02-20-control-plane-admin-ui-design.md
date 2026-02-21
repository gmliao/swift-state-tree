# Control Plane Admin UI Design

> **Status:** Design approved. Implementation plan: `2026-02-20-control-plane-admin-ui-implementation-plan.md`

## Goal

Provide a management and monitoring web UI for the matchmaking control plane. Operators can view registered game servers, queue status, and health at a glance.

## Scope (MVP)

- **Read-only dashboard**: Servers list, queue summary, health status
- **Tech stack**: Vue 3, Vuetify 3, Pinia
- **Testing**: Unit tests (Vitest), Playwright browser e2e, CLI HTTP e2e for admin API

## Out of Scope (MVP)

- Write operations (deregister server, cancel ticket from UI)
- Authentication (local dev only; document prod auth requirements)
- Real-time WebSocket updates (polling only)

---

## Architecture

```
┌─────────────────────┐     GET /v1/admin/*      ┌──────────────────────────┐
│  Admin Web UI       │ ◄─────────────────────── │  Control Plane (NestJS)   │
│  Vue3 + Vuetify     │                          │  + AdminModule            │
│  Pinia              │                          │  ServerRegistryService    │
│  Packages/control-  │                          │  MatchmakingStore         │
│  plane-admin-ui/    │                          └──────────────────────────┘
└─────────────────────┘
```

- Admin UI is a separate Vite + Vue app, served as static files or via control plane static middleware
- Admin API endpoints are read-only; no new write operations
- CORS: Same-origin when served by control plane; document `ADMIN_UI_ORIGIN` for dev proxy

---

## Admin API (NestJS)

Add `AdminModule` with `AdminController`:

| Method | Path | Description |
|--------|------|-------------|
| GET | /v1/admin/servers | List all registered servers (from ServerRegistryService) |
| GET | /v1/admin/health | Control plane health (reuse /health or alias) |
| GET | /v1/admin/queue/summary | Queue keys and queued ticket counts (from MatchmakingStore) |

### Data Contracts

**GET /v1/admin/servers** response:
```json
{
  "servers": [
    {
      "serverId": "game-1",
      "host": "127.0.0.1",
      "port": 8080,
      "landType": "hero-defense",
      "connectHost": null,
      "connectPort": null,
      "connectScheme": "ws",
      "registeredAt": "2026-02-20T00:00:00.000Z",
      "lastSeenAt": "2026-02-20T00:01:00.000Z",
      "isStale": false
    }
  ]
}
```

**GET /v1/admin/queue/summary** response:
```json
{
  "queueKeys": ["standard:asia", "standard:eu"],
  "byQueueKey": {
    "standard:asia": { "queuedCount": 3 },
    "standard:eu": { "queuedCount": 1 }
  }
}
```

### ServerRegistryService Extension

Add `listAllServers(): ServerEntry[]` to expose all entries for admin. Implementation: iterate `serversByLandType`, flatten, mark `isStale` if `lastSeenAt` older than TTL.

### Queue Summary

Use existing `MatchmakingStore` / `ApiMatchQueue` or `LocalMatchQueue` `listQueueKeysWithQueued()` and `listQueuedByQueue()`. Admin controller injects the appropriate store/queue and aggregates counts.

---

## Admin UI (Vue 3 + Vuetify + Pinia)

### Structure

```
Packages/control-plane-admin-ui/
├── src/
│   ├── main.ts
│   ├── App.vue
│   ├── router/
│   ├── stores/
│   │   └── admin.ts          # Pinia: fetch servers, queue summary
│   ├── views/
│   │   ├── DashboardView.vue
│   │   └── ServersView.vue
│   ├── components/
│   │   ├── ServerTable.vue
│   │   └── QueueSummaryCard.vue
│   └── api/
│       └── adminApi.ts       # HTTP client for /v1/admin/*
├── tests/
│   ├── unit/                 # Vitest
│   └── e2e/                  # Playwright
├── package.json
├── vite.config.ts
├── vitest.config.ts
└── playwright.config.ts
```

### Views

1. **Dashboard**: Health status, queue summary cards, recent servers count
2. **Servers**: Data table of all servers (serverId, landType, host:port, lastSeenAt, isStale)

### Data Flow

- Pinia store `useAdminStore` fetches from `/v1/admin/servers` and `/v1/admin/queue/summary`
- Polling every 5–10 seconds (configurable)
- Components consume store state; no direct API calls in components

### Styling

- Vuetify 3 default theme; optional dark mode toggle later
- Responsive layout: cards stack on mobile, table scrolls horizontally

---

## Testing Strategy

### 1. Unit Tests (Vitest)

- **Stores**: `adminStore` fetch, error handling, polling
- **Components**: ServerTable, QueueSummaryCard with mocked store
- **API client**: `adminApi.getServers()`, `adminApi.getQueueSummary()` with mocked fetch

### 2. Playwright E2E

- Navigate to dashboard, verify health and queue summary render
- Navigate to servers, verify table shows data (with seeded control plane)
- Test setup: Start control plane + register mock server, run Playwright against `http://localhost:3000/admin` (or dev server)

### 3. CLI E2E (Admin API)

- Add `Tools/CLI/scenarios/admin/` with JSON scenarios for HTTP GET
- Or: `Packages/control-plane/test/admin.e2e-spec.ts` (Jest) that hits admin endpoints
- Prefer NestJS Jest e2e for admin API (consistent with control plane); CLI scenarios optional for smoke

**Decision**: Use NestJS Jest e2e for admin API (`admin.e2e-spec.ts`). Playwright for UI. Vitest for frontend unit tests.

---

## Security Notes

- **MVP**: No auth; admin endpoints are read-only
- **Production**: Document requirement for reverse proxy auth (e.g., nginx basic auth, OIDC) or `ADMIN_API_KEY` header validation in future iteration

---

## File Summary

| Layer | Path |
|-------|------|
| Admin API | `Packages/control-plane/src/modules/admin/` |
| Admin UI | `Packages/control-plane-admin-ui/` |
| Admin API e2e | `Packages/control-plane/test/admin.e2e-spec.ts` |
| UI unit | `Packages/control-plane-admin-ui/tests/unit/` |
| UI e2e | `Packages/control-plane-admin-ui/tests/e2e/` (Playwright) |
