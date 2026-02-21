# Control Plane Admin UI Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a read-only management/monitoring web UI for the matchmaking control plane (Vue 3, Vuetify, Pinia) with Admin API, unit tests, Playwright e2e, and NestJS admin API e2e tests.

**Architecture:** Admin UI as separate Vite app in `Packages/control-plane-admin-ui/`. Control plane gains `AdminModule` with read-only REST endpoints. Servers and queue summary exposed via new `listAllServers()` and queue aggregation.

**Tech Stack:** Vue 3, Vuetify 3, Pinia, Vite, Vitest, Playwright; NestJS (control plane), Jest (admin API e2e).

---

## Phase 1: Admin API (Control Plane)

### Task 1: ServerRegistryService.listAllServers

**Files:**
- Modify: `Packages/control-plane/src/modules/provisioning/server-registry.service.ts`
- Test: `Packages/control-plane/src/modules/provisioning/server-registry.service.spec.ts` (create if missing)

**Step 1: Write the failing test**

Create or extend `server-registry.service.spec.ts`:

```typescript
it('listAllServers returns all entries with isStale', () => {
  const registry = new ServerRegistryService();
  registry.register('s1', '127.0.0.1', 8080, 'hero-defense');
  registry.register('s2', '127.0.0.1', 8081, 'hero-defense');
  const list = registry.listAllServers();
  expect(list).toHaveLength(2);
  expect(list[0]).toMatchObject({ serverId: 's1', landType: 'hero-defense', isStale: false });
});
```

**Step 2: Run test to verify it fails**

Run: `cd Packages/control-plane && npm test -- server-registry.service.spec`
Expected: FAIL (listAllServers not defined)

**Step 3: Add listAllServers to ServerRegistryService**

```typescript
listAllServers(): (ServerEntry & { isStale: boolean })[] {
  const cutoff = Date.now() - SERVER_TTL_MS;
  const result: (ServerEntry & { isStale: boolean })[] = [];
  for (const entries of this.serversByLandType.values()) {
    for (const e of entries) {
      result.push({ ...e, isStale: e.lastSeenAt.getTime() < cutoff });
    }
  }
  return result;
}
```

**Step 4: Run test to verify it passes**

Run: `cd Packages/control-plane && npm test -- server-registry.service.spec`
Expected: PASS

**Step 5: Commit**

```bash
git add Packages/control-plane/src/modules/provisioning/
git commit -m "feat(control-plane): add listAllServers to ServerRegistryService"
```

---

### Task 2: Queue summary aggregation (MatchmakingStore + AdminQueueService)

**Files:**
- Modify: `Packages/control-plane/src/modules/matchmaking/matchmaking-store.ts` – add `listAllQueuedTickets()`
- Modify: `Packages/control-plane/src/modules/matchmaking/storage/redis-matchmaking-store.ts` – implement via HGETALL on `matchmaking:queued`
- Create: `Packages/control-plane/src/modules/admin/admin-queue.service.ts`

**Step 1: Add listAllQueuedTickets to MatchmakingStore interface**

```typescript
/** List all queued tickets (for admin dashboard). */
listAllQueuedTickets(): Promise<QueuedTicket[]>;
```

**Step 2: Implement in RedisMatchmakingStore**

```typescript
async listAllQueuedTickets(): Promise<QueuedTicket[]> {
  const redis = await this.getRedis();
  const raw = await redis.hgetall(QUEUED_KEY);
  if (!raw || Object.keys(raw).length === 0) return [];
  return Object.values(raw).map((v) => {
    const t = JSON.parse(v as string) as QueuedTicket;
    t.createdAt = new Date(t.createdAt as unknown as string);
    return t;
  });
}
```

**Step 3: Add in-memory implementation** (for tests): Check if there is InMemoryMatchmakingStore or similar; add stub returning `[]` if needed.

**Step 4: Create AdminQueueService**

```typescript
@Injectable()
export class AdminQueueService {
  constructor(@Inject('MatchmakingStore') private readonly store: MatchmakingStore) {}
  async getQueueSummary(): Promise<{ queueKeys: string[]; byQueueKey: Record<string, { queuedCount: number }> }> {
    const tickets = await this.store.listAllQueuedTickets();
    const byQueueKey: Record<string, { queuedCount: number }> = {};
    for (const t of tickets) {
      const k = t.queueKey;
      if (!byQueueKey[k]) byQueueKey[k] = { queuedCount: 0 };
      byQueueKey[k].queuedCount++;
    }
    return { queueKeys: Object.keys(byQueueKey), byQueueKey };
  }
}
```

**Step 5: Add unit test for AdminQueueService**

Mock store.listAllQueuedTickets, verify summary shape.

**Step 6: Commit**

```bash
git add Packages/control-plane/src/modules/matchmaking/ Packages/control-plane/src/modules/admin/
git commit -m "feat(control-plane): add listAllQueuedTickets and AdminQueueService for queue summary"
```

---

### Task 3: AdminController and AdminModule

**Files:**
- Create: `Packages/control-plane/src/modules/admin/admin.controller.ts`
- Create: `Packages/control-plane/src/modules/admin/admin.module.ts`
- Create: `Packages/control-plane/src/modules/admin/dto/admin-response.dto.ts`
- Modify: `Packages/control-plane/src/app.module.ts`

**Step 1: Create DTOs**

`dto/admin-response.dto.ts`:

```typescript
export class ServerListResponseDto {
  servers: Array<{
    serverId: string;
    host: string;
    port: number;
    landType: string;
    connectHost?: string;
    connectPort?: number;
    connectScheme?: string;
    registeredAt: string;
    lastSeenAt: string;
    isStale: boolean;
  }>;
}

export class QueueSummaryResponseDto {
  queueKeys: string[];
  byQueueKey: Record<string, { queuedCount: number }>;
}
```

**Step 2: Create AdminController**

```typescript
@Controller('v1/admin')
@ApiTags('admin')
export class AdminController {
  constructor(
    private readonly registry: ServerRegistryService,
    private readonly queueSummary: AdminQueueService,
  ) {}

  @Get('servers')
  getServers(): ServerListResponseDto {
    const list = this.registry.listAllServers();
    return {
      servers: list.map((e) => ({
        serverId: e.serverId,
        host: e.host,
        port: e.port,
        landType: e.landType,
        connectHost: e.connectHost,
        connectPort: e.connectPort,
        connectScheme: e.connectScheme,
        registeredAt: e.registeredAt.toISOString(),
        lastSeenAt: e.lastSeenAt.toISOString(),
        isStale: e.isStale,
      })),
    };
  }

  @Get('queue/summary')
  async getQueueSummary(): Promise<QueueSummaryResponseDto> {
    return this.queueSummary.getQueueSummary();
  }
}
```

**Step 3: Create AdminModule, register in AppModule**

**Step 4: Add admin.e2e-spec.ts**

```typescript
describe('AdminController (e2e)', () => {
  it('GET /v1/admin/servers returns empty list', async () => {
    const res = await request(app.getHttpServer()).get('/v1/admin/servers');
    expect(res.status).toBe(200);
    expect(res.body.servers).toEqual([]);
  });
  it('GET /v1/admin/queue/summary returns summary', async () => {
    const res = await request(app.getHttpServer()).get('/v1/admin/queue/summary');
    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty('queueKeys');
    expect(res.body).toHaveProperty('byQueueKey');
  });
});
```

**Step 5: Run e2e**

Run: `cd Packages/control-plane && npm run test:e2e -- --testPathPattern=admin`
Expected: PASS

**Step 6: Commit**

```bash
git add Packages/control-plane/src/modules/admin/ Packages/control-plane/src/app.module.ts Packages/control-plane/test/admin.e2e-spec.ts
git commit -m "feat(control-plane): add AdminModule with servers and queue summary endpoints"
```

---

## Phase 2: Admin UI (Vue 3 + Vuetify + Pinia)

### Task 4: Scaffold Admin UI project

**Files:**
- Create: `Packages/control-plane-admin-ui/package.json`
- Create: `Packages/control-plane-admin-ui/vite.config.ts`
- Create: `Packages/control-plane-admin-ui/tsconfig.json`
- Create: `Packages/control-plane-admin-ui/index.html`
- Create: `Packages/control-plane-admin-ui/src/main.ts`
- Create: `Packages/control-plane-admin-ui/src/App.vue`

**Step 1: Create package.json**

```json
{
  "name": "control-plane-admin-ui",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vue-tsc -b && vite build",
    "preview": "vite preview",
    "test": "vitest run",
    "test:e2e": "playwright test"
  },
  "dependencies": {
    "vue": "^3.5.0",
    "vue-router": "^4.6.0",
    "pinia": "^2.2.0",
    "vuetify": "^3.11.0",
    "@mdi/font": "^7.4.0"
  },
  "devDependencies": {
    "@vitejs/plugin-vue": "^6.0.0",
    "vite": "^7.0.0",
    "vue-tsc": "^2.0.0",
    "typescript": "~5.6.0",
    "vitest": "^2.1.0",
    "@vue/test-utils": "^2.4.0",
    "jsdom": "^25.0.0",
    "@playwright/test": "^1.49.0",
    "vite-plugin-vuetify": "^2.1.0",
    "sass": "^1.77.0"
  }
}
```

**Step 2: Create vite.config.ts with Vue, Vuetify, path alias**

**Step 3: Create vitest.config.ts**

**Step 4: Create playwright.config.ts**

```typescript
import { defineConfig, devices } from '@playwright/test';
export default defineConfig({
  testDir: './tests/e2e',
  webServer: {
    command: 'npm run dev',
    url: 'http://localhost:5174',
    reuseExistingServer: !process.env.CI,
  },
  use: { baseURL: 'http://localhost:5174' },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
});
```

**Step 5: Commit**

```bash
git add Packages/control-plane-admin-ui/
git commit -m "chore: scaffold control-plane-admin-ui (Vue3, Vuetify, Pinia, Vite, Vitest, Playwright)"
```

---

### Task 5: Admin API client and Pinia store

**Files:**
- Create: `Packages/control-plane-admin-ui/src/api/adminApi.ts`
- Create: `Packages/control-plane-admin-ui/src/stores/admin.ts`

**Step 1: Write adminApi.ts**

```typescript
const BASE = import.meta.env.VITE_ADMIN_API_BASE ?? '/api'; // proxy to control plane in dev

export async function getServers() {
  const r = await fetch(`${BASE}/v1/admin/servers`);
  if (!r.ok) throw new Error(`getServers failed: ${r.status}`);
  return r.json();
}

export async function getQueueSummary() {
  const r = await fetch(`${BASE}/v1/admin/queue/summary`);
  if (!r.ok) throw new Error(`getQueueSummary failed: ${r.status}`);
  return r.json();
}
```

**Step 2: Write Pinia store admin.ts**

State: `servers`, `queueSummary`, `loading`, `error`. Actions: `fetchServers`, `fetchQueueSummary`, `fetchAll` (calls both). Optional: `startPolling(intervalMs)`, `stopPolling`.

**Step 3: Write unit tests for adminApi (mocked fetch)**

**Step 4: Write unit tests for admin store (mocked adminApi)**

**Step 5: Commit**

```bash
git add Packages/control-plane-admin-ui/src/api/ Packages/control-plane-admin-ui/src/stores/ Packages/control-plane-admin-ui/tests/
git commit -m "feat(admin-ui): add admin API client and Pinia store with unit tests"
```

---

### Task 6: Dashboard and Servers views

**Files:**
- Create: `Packages/control-plane-admin-ui/src/router/index.ts`
- Create: `Packages/control-plane-admin-ui/src/views/DashboardView.vue`
- Create: `Packages/control-plane-admin-ui/src/views/ServersView.vue`
- Create: `Packages/control-plane-admin-ui/src/components/ServerTable.vue`
- Create: `Packages/control-plane-admin-ui/src/components/QueueSummaryCard.vue`
- Modify: `Packages/control-plane-admin-ui/src/App.vue`

**Step 1: Create router with / and /servers**

**Step 2: Create QueueSummaryCard** – displays queueKeys and counts from store

**Step 3: Create ServerTable** – v-data-table with serverId, landType, host:port, lastSeenAt, isStale

**Step 4: Create DashboardView** – health, QueueSummaryCard, link to Servers

**Step 5: Create ServersView** – ServerTable, fetch on mount

**Step 6: Add unit tests for QueueSummaryCard and ServerTable (mocked store)**

**Step 7: Commit**

```bash
git add Packages/control-plane-admin-ui/src/
git commit -m "feat(admin-ui): add Dashboard and Servers views with components"
```

---

### Task 7: Playwright e2e tests

**Files:**
- Create: `Packages/control-plane-admin-ui/tests/e2e/dashboard.spec.ts`
- Create: `Packages/control-plane-admin-ui/tests/e2e/servers.spec.ts`
- Modify: `Packages/control-plane-admin-ui/playwright.config.ts` if needed (e.g., API base URL for control plane)

**Step 1: Configure Playwright to use control plane API**

Option A: Admin UI dev server proxies `/api` to control plane (vite proxy).
Option B: Playwright starts both control plane and admin UI; set `VITE_ADMIN_API_BASE=http://localhost:3000` for admin UI.

**Step 2: Write dashboard.spec.ts**

- Navigate to /
- Expect: page contains "Dashboard" or "Control Plane"
- Expect: queue summary section exists (can be empty)

**Step 3: Write servers.spec.ts**

- Register a mock server via control plane API (fetch POST /v1/provisioning/servers/register)
- Navigate to /servers
- Expect: table contains the registered server

**Step 4: Run Playwright**

Run: `cd Packages/control-plane-admin-ui && npm run test:e2e`
Expected: PASS (requires control plane running or playwright webServer starts it – add to config if needed)

**Step 5: Commit**

```bash
git add Packages/control-plane-admin-ui/tests/e2e/ Packages/control-plane-admin-ui/playwright.config.ts
git commit -m "test(admin-ui): add Playwright e2e tests for dashboard and servers"
```

---

### Task 8: CLI / integration e2e for admin API

**Files:**
- Modify: `Packages/control-plane/test/admin.e2e-spec.ts` (extend with registered server + queue scenario)

**Step 1: Add e2e scenario: register server, then GET /v1/admin/servers**

- Create test app with provisioning
- POST register a server
- GET /v1/admin/servers, expect servers length 1

**Step 2: Add e2e scenario: enqueue ticket, then GET /v1/admin/queue/summary**

- Enqueue a ticket
- GET /v1/admin/queue/summary, expect non-empty queueKeys or byQueueKey

**Step 3: Run e2e**

Run: `cd Packages/control-plane && npm run test:e2e -- --testPathPattern=admin`
Expected: PASS

**Step 4: Commit**

```bash
git add Packages/control-plane/test/admin.e2e-spec.ts
git commit -m "test(control-plane): extend admin e2e with server and queue scenarios"
```

---

### Task 9: Wire admin UI to control plane (dev workflow)

**Files:**
- Modify: `Packages/control-plane-admin-ui/vite.config.ts` – add proxy `/api` -> `http://localhost:3000`
- Modify: `Packages/control-plane/README.md` – document running admin UI
- Create: `Packages/control-plane-admin-ui/README.md`

**Step 1: Add Vite proxy**

```typescript
server: {
  port: 5174,
  proxy: {
    '/api': { target: 'http://localhost:3000', changeOrigin: true },
  },
},
```

**Step 2: Update adminApi to use `/api` as default base**

**Step 3: Document in README**

- Start control plane: `cd Packages/control-plane && npm run start:dev`
- Start admin UI: `cd Packages/control-plane-admin-ui && npm run dev`
- Open http://localhost:5174

**Step 4: Commit**

```bash
git add Packages/control-plane-admin-ui/vite.config.ts Packages/control-plane-admin-ui/src/api/adminApi.ts READMEs
git commit -m "chore: wire admin UI to control plane with dev proxy and docs"
```

---

### Task 10: CI integration

**Files:**
- Modify: `.github/workflows/` (add or extend workflow for admin UI tests)

**Step 1: Add job for control-plane admin e2e**

Ensure `admin.e2e-spec.ts` runs in existing control-plane e2e job.

**Step 2: Add job for admin-ui**

- Install deps, build
- Run `npm test` (Vitest)
- Run Playwright: start control plane in background, then `npm run test:e2e`

**Step 3: Commit**

```bash
git add .github/workflows/
git commit -m "ci: add admin UI and admin API e2e to workflows"
```

---

## Execution Handoff

Plan complete and saved to `docs/plans/2026-02-20-control-plane-admin-ui-implementation-plan.md`.

**Two execution options:**

1. **Subagent-Driven (this session)** – Dispatch fresh subagent per task, review between tasks, fast iteration.
2. **Parallel Session (separate)** – Open new session with executing-plans, batch execution with checkpoints.

**Which approach?**
