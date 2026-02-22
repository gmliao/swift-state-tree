# Control Plane TypeScript Client SDK Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship a standalone TypeScript client SDK at `Packages/control-plane-ts-client/` that provides matchmaking (enqueue, cancel, status), Realtime WebSocket, admin read-only APIs, and a high-level `findMatch()` returning `Promise<Assignment>`, then wire GameDemo WebClient to use it.

**Architecture:** Thin `ControlPlaneClient` class using `fetch` and `WebSocket`; types as plain TS interfaces aligned with control-plane; `findMatch()` uses Realtime WS (with optional polling fallback) and supports timeout/AbortSignal. GameDemo WebClient composes `connectUrl + token` and calls existing game SDK.

**Tech Stack:** TypeScript, fetch, WebSocket, Vitest for unit tests. No NestJS or control-plane dependency.

**Branch:** Create and work on a new branch in the repo (e.g. `feat/control-plane-ts-client`). No worktree required.

---

## Task 1: Create package scaffold

**Files:**
- Create: `Packages/control-plane-ts-client/package.json`
- Create: `Packages/control-plane-ts-client/tsconfig.json`
- Create: `Packages/control-plane-ts-client/src/index.ts` (empty re-exports for now)

**Step 1: Add package.json**

Contents (adjust `name` if your org scope differs):

```json
{
  "name": "@swiftstatetree/control-plane-client",
  "version": "0.1.0",
  "description": "TypeScript client for SwiftStateTree control plane (matchmaking, admin)",
  "type": "module",
  "main": "./dist/index.js",
  "types": "./dist/index.d.ts",
  "exports": {
    ".": { "import": "./dist/index.js", "types": "./dist/index.d.ts" }
  },
  "scripts": {
    "build": "tsc -p tsconfig.json",
    "test": "vitest run",
    "test:watch": "vitest"
  },
  "devDependencies": {
    "typescript": "^5.3.0",
    "vitest": "^2.1.0"
  }
}
```

**Step 2: Add tsconfig.json**

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "outDir": "dist",
    "rootDir": "src",
    "strict": true,
    "declaration": true,
    "declarationMap": true,
    "sourceMap": true,
    "skipLibCheck": true
  },
  "include": ["src/**/*"],
  "exclude": ["node_modules", "dist", "**/*.test.ts"]
}
```

**Step 3: Add vitest config**

Create `Packages/control-plane-ts-client/vitest.config.ts`:

```ts
import { defineConfig } from 'vitest/config';
import ts from 'typescript';
export default defineConfig({
  test: {
    globals: true,
  },
  resolve: {
    extensions: ['.ts'],
  },
});
```

**Step 4: Create src/index.ts**

```ts
// Placeholder; will re-export client and types in later tasks.
export {};
```

**Step 5: Install deps and build**

Run: `cd Packages/control-plane-ts-client && npm install && npm run build`  
Expected: Build succeeds; `dist/index.js` and `dist/index.d.ts` exist.

**Step 6: Commit**

```bash
git checkout -b feat/control-plane-ts-client
git add Packages/control-plane-ts-client/
git commit -m "chore: add control-plane-ts-client package scaffold"
```

---

## Task 2: Define types

**Files:**
- Create: `Packages/control-plane-ts-client/src/types.ts`
- Modify: `Packages/control-plane-ts-client/src/index.ts` (re-export types)

**Step 1: Add types.ts**

Define interfaces aligned with control-plane (see `Packages/control-plane/src/infra/contracts/matchmaking.dto.ts`, `assignment.dto.ts`, `Packages/control-plane/src/modules/admin/dto/admin-response.dto.ts`):

```ts
// Matchmaking
export type TicketStatus = 'queued' | 'assigned' | 'cancelled' | 'expired';

export interface EnqueueRequest {
  queueKey: string;
  groupId?: string;
  members: string[];
  groupSize: number;
  region?: string;
  constraints?: Record<string, unknown>;
}

export interface EnqueueResponse {
  ticketId: string;
  status: 'queued';
}

export interface CancelResponse {
  cancelled: boolean;
}

export interface Assignment {
  assignmentId: string;
  matchToken: string;
  connectUrl: string;
  landId: string;
  serverId: string;
  expiresAt: string;
}

export interface StatusResponse {
  ticketId: string;
  status: TicketStatus;
  assignment?: Assignment;
}

// Admin
export interface ServerEntry {
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
}

export interface ServerListResponse {
  servers: ServerEntry[];
}

export interface QueueSummaryResponse {
  queueKeys: string[];
  byQueueKey: Record<string, { queuedCount: number }>;
}
```

**Step 2: Re-export from index.ts**

In `src/index.ts`, replace placeholder with:

```ts
export type {
  TicketStatus,
  EnqueueRequest,
  EnqueueResponse,
  CancelResponse,
  Assignment,
  StatusResponse,
  ServerEntry,
  ServerListResponse,
  QueueSummaryResponse,
} from './types.js';
```

**Step 3: Build**

Run: `cd Packages/control-plane-ts-client && npm run build`  
Expected: PASS.

**Step 4: Commit**

```bash
git add Packages/control-plane-ts-client/src/
git commit -m "feat(control-plane-client): add shared types"
```

---

## Task 3: ControlPlaneClient – REST (enqueue, cancel, getStatus)

**Files:**
- Create: `Packages/control-plane-ts-client/src/client.ts`
- Create: `Packages/control-plane-ts-client/src/client.test.ts`
- Modify: `Packages/control-plane-ts-client/src/index.ts` (export client)

**Step 1: Write failing test**

In `src/client.test.ts`, add test that calls `client.enqueue(...)` and expects a response (will fail until client exists). Use a mock: intercept `fetch` (e.g. with vitest `vi.stubGlobal('fetch', ...)`) to return `{ ticketId: 't1', status: 'queued' }` for POST to `/v1/matchmaking/enqueue`. Assert request URL and body shape; assert resolved value.

**Step 2: Run test**

Run: `cd Packages/control-plane-ts-client && npm test`  
Expected: FAIL (client or enqueue not defined).

**Step 3: Implement ControlPlaneClient (REST only)**

In `src/client.ts`:
- Constructor `ControlPlaneClient(baseUrl: string, options?: { fetch?: typeof fetch; adminApiKey?: string })`. Normalize `baseUrl` (trim trailing slash).
- Private `request<T>(path, init?: RequestInit): Promise<T>` that uses `this.fetch` (default `globalThis.fetch`), builds URL as `baseUrl + path`, sends JSON when body provided, and throws on non-2xx with status and body text.
- `enqueue(request: EnqueueRequest): Promise<EnqueueResponse>` → `POST /v1/matchmaking/enqueue`, body JSON.
- `cancel(ticketId: string): Promise<CancelResponse>` → `POST /v1/matchmaking/cancel`, body `{ ticketId }`.
- `getStatus(ticketId: string): Promise<StatusResponse>` → `GET /v1/matchmaking/status/${encodeURIComponent(ticketId)}`.

**Step 4: Re-export client from index**

Add to `src/index.ts`: `export { ControlPlaneClient } from './client.js';`

**Step 5: Run test**

Run: `cd Packages/control-plane-ts-client && npm test`  
Expected: PASS for the enqueue (and add similar tests for cancel and getStatus with mocks).

**Step 6: Commit**

```bash
git add Packages/control-plane-ts-client/src/
git commit -m "feat(control-plane-client): add ControlPlaneClient REST (enqueue, cancel, status)"
```

---

## Task 4: ControlPlaneClient – Admin (getServers, getQueueSummary)

**Files:**
- Modify: `Packages/control-plane-ts-client/src/client.ts` (add getServers, getQueueSummary; add optional admin header when adminApiKey set)
- Modify: `Packages/control-plane-ts-client/src/client.test.ts` (add tests with mocked fetch)

**Step 1: Write failing tests**

Add tests: `getServers()` returns `{ servers: [...] }` and `getQueueSummary()` returns `{ queueKeys, byQueueKey }` when fetch is mocked. Optionally assert that when `adminApiKey` is set, request headers include the key (e.g. `Authorization: Bearer <key>` or header name per control-plane contract).

**Step 2: Run tests**

Expected: FAIL (method not implemented).

**Step 3: Implement**

- In `request()`, if `this.adminApiKey` is set and path starts with `/v1/admin/`, add header (document control-plane’s expected header name; if unknown, use `Authorization: Bearer ${this.adminApiKey}` or leave a TODO).
- `getServers(): Promise<ServerListResponse>` → `GET /v1/admin/servers`.
- `getQueueSummary(): Promise<QueueSummaryResponse>` → `GET /v1/admin/queue/summary`.

**Step 4: Run tests**

Expected: PASS.

**Step 5: Commit**

```bash
git add Packages/control-plane-ts-client/src/
git commit -m "feat(control-plane-client): add admin getServers and getQueueSummary"
```

---

## Task 5: Realtime WebSocket (openRealtimeSocket, RealtimeSocket)

**Files:**
- Create: `Packages/control-plane-ts-client/src/realtime.ts`
- Modify: `Packages/control-plane-ts-client/src/client.ts` (add openRealtimeSocket)
- Create or modify: `Packages/control-plane-ts-client/src/realtime.test.ts` (mock WebSocket)

**Step 1: Write failing test**

Test that `client.openRealtimeSocket(ticketId)` returns an object with `on('match.assigned', cb)`, and when a mock WS receives a message `{ type: 'match.assigned', v: 1, data: { ticketId, assignment } }`, the callback is invoked with `assignment`. Test `on('enqueued', cb)` and `close()`.

**Step 2: Run test**

Expected: FAIL.

**Step 3: Implement**

- In `realtime.ts`: `RealtimeSocket` class or factory that wraps `WebSocket`. Constructor takes `wsUrl: string`. Parse incoming messages as JSON; if `type === 'match.assigned'`, emit to registered callback with `data.assignment`; if `type === 'enqueued'`, emit with `data.ticketId` (and status). Expose `on(event, cb)`, `sendEnqueue(params)` (send `{ action: 'enqueue', ... }`), `close()`.
- In `client.ts`: `openRealtimeSocket(ticketId?: string): Promise<RealtimeSocket>`. Build WS URL: baseUrl → replace `http` with `ws`, `https` with `wss`, append `/realtime` and if `ticketId` then `?ticketId=...`. Return a Promise that resolves when WebSocket opens (or reject on error). Pass the socket to `RealtimeSocket` wrapper.

**Step 4: Run tests**

Expected: PASS.

**Step 5: Export**

Export `RealtimeSocket` (or its type) from `index.ts` if needed by callers.

**Step 6: Commit**

```bash
git add Packages/control-plane-ts-client/src/
git commit -m "feat(control-plane-client): add Realtime WebSocket (openRealtimeSocket, RealtimeSocket)"
```

---

## Task 6: findMatch with timeout and AbortSignal

**Files:**
- Create: `Packages/control-plane-ts-client/src/findMatch.ts`
- Create: `Packages/control-plane-ts-client/src/findMatch.test.ts`
- Modify: `Packages/control-plane-ts-client/src/index.ts` (export findMatch and FindMatchOptions)

**Step 1: Define FindMatchOptions and errors**

- `FindMatchOptions` extends enqueue params and adds `timeoutMs?: number` (default 60_000), `signal?: AbortSignal`.
- Custom error: `FindMatchTimeoutError` (or reject with `{ code: 'FIND_MATCH_TIMEOUT' }`). On abort, reject with `AbortError` or `{ code: 'ABORTED' }`. On status `cancelled`/`expired`, reject with clear message.

**Step 2: Write failing test**

Mock `ControlPlaneClient`: enqueue resolves with `{ ticketId: 't1', status: 'queued' }`. Mock RealtimeSocket: after open, emit `match.assigned` with an `assignment`. Call `findMatch(client, { queueKey: 'q', members: ['p1'], groupSize: 1 })` and assert it resolves to that assignment. Add test for timeout (mock no assignment until after timeout) and assert rejection. Add test for abort (signal.abort() before assignment) and assert rejection.

**Step 3: Run test**

Expected: FAIL.

**Step 4: Implement findMatch**

- Call `client.enqueue(options)` to get `ticketId`.
- Open Realtime socket with `ticketId`. On `match.assigned`, resolve with `data.assignment` and close socket.
- If `signal` is provided, listen for `abort` and reject with AbortError, then close socket.
- Start a timeout timer (`timeoutMs`); if it fires before resolution, reject with FindMatchTimeoutError and close socket.
- Optional fallback: if Realtime fails to connect, fall back to polling `getStatus(ticketId)` on an interval until assigned/cancelled/expired/timeout; then resolve or reject accordingly. (Can be a follow-up task to keep MVP small.)

**Step 5: Run tests**

Expected: PASS.

**Step 6: Export**

Export `findMatch`, `FindMatchOptions`, and error types from `index.ts`.

**Step 7: Commit**

```bash
git add Packages/control-plane-ts-client/src/
git commit -m "feat(control-plane-client): add findMatch with timeout and AbortSignal"
```

---

## Task 7: GameDemo WebClient – dependency and “Find Match” flow

**Files:**
- Modify: `Examples/GameDemo/WebClient/package.json` (add dependency on control-plane-ts-client: workspace or file path)
- Modify: `Examples/GameDemo/WebClient/src/views/ConnectView.vue` (add “Find Match” path: control-plane base URL input, findMatch, then connect to game with connectUrl + token)

**Step 1: Add dependency**

In `Examples/GameDemo/WebClient/package.json`, add:

```json
"@swiftstatetree/control-plane-client": "file:../../../Packages/control-plane-ts-client"
```
(or use workspace reference if repo root has workspaces configured).

Run `npm install` in WebClient so the dependency resolves.

**Step 2: Implement Find Match in ConnectView**

- Add UI: input for control-plane base URL (e.g. `http://localhost:3000`), and a “Find Match” button (or second flow). When clicked: create `ControlPlaneClient(baseUrl)`, call `findMatch(client, { queueKey: 'hero-defense', members: [playerName], groupSize: 1 })` (use existing `playerName` or a dedicated field). On success, build `finalWsUrl = assignment.connectUrl + (assignment.connectUrl.includes('?') ? '&' : '?') + 'token=' + encodeURIComponent(assignment.matchToken)`, then call `useGameClient().connect({ wsUrl: finalWsUrl, playerName, landID: assignment.landId })` and navigate to game. On error, show message (e.g. “Matchmaking timed out” or lastError).
- Keep existing “manual” connect (wsUrl + roomId) so both flows are available.

**Step 3: Manual test**

Start control-plane (with provisioning + game server) and GameServer; open WebClient; use “Find Match” and confirm assignment and game connection. Verify manual connect still works.

**Step 4: Commit**

```bash
git add Examples/GameDemo/WebClient/
git commit -m "feat(webclient): integrate control-plane client SDK (Find Match flow)"
```

---

## Task 8: README and package exports

**Files:**
- Create: `Packages/control-plane-ts-client/README.md`
- Modify: `Packages/control-plane-ts-client/src/index.ts` (ensure all public API and types exported)

**Step 1: README**

Document: install, basic usage (`ControlPlaneClient`, `findMatch`), building game URL with `connectUrl + token`, optional admin and RealtimeSocket usage, and link to control-plane API docs if any.

**Step 2: Final export check**

Ensure `index.ts` exports: `ControlPlaneClient`, `findMatch`, `FindMatchOptions`, `RealtimeSocket` (if applicable), all types from Task 2, and error types from Task 6.

**Step 3: Commit**

```bash
git add Packages/control-plane-ts-client/README.md Packages/control-plane-ts-client/src/index.ts
git commit -m "docs(control-plane-client): add README and finalize exports"
```

---

## Execution

Plan complete and saved to `docs/plans/2026-02-22-control-plane-ts-client-implementation-plan.md`.

**Two execution options:**

1. **Subagent-Driven (this session)** – I dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Parallel Session (separate)** – Open a new session with executing-plans and run through the plan with checkpoints.

Which approach do you prefer?
