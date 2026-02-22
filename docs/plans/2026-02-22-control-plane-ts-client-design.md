# Control Plane TypeScript Client SDK Design

> **Status:** Design approved. Implementation plan: `2026-02-22-control-plane-ts-client-implementation-plan.md`
> **Branch:** New branch in repo (no worktree).

## Goal

Provide a TypeScript client SDK for the matchmaking control plane so that frontends (e.g. GameDemo WebClient) can easily integrate: enqueue, wait for assignment, then connect to the game server using the returned `connectUrl` and `matchToken`.

## Scope (MVP)

- **Package:** Standalone package at `Packages/control-plane-ts-client/` (option B: sibling to control-plane).
- **Features:** Matchmaking (enqueue, cancel, status) + Realtime WebSocket (subscribe to `match.assigned`) + Admin read-only (list servers, queue summary).
- **API style:** Thin client (`ControlPlaneClient`) + high-level `findMatch(client, options)` that returns `Promise<Assignment>`.
- **Runtime:** Browser and Node; only `fetch` and `WebSocket`; no dependency on control-plane package.
- **Primary consumer:** GameDemo WebClient (connect via matchmaking instead of manual wsUrl/roomId).

## Out of Scope (MVP)

- Automatic retries or re-enqueue inside the SDK.
- Vue/React composables (callers use the SDK directly; WebClient can wrap in a composable if needed).
- Provisioning or other control-plane APIs not listed above.

---

## Architecture & Package Structure

- **Location:** `Packages/control-plane-ts-client/` (same level as `Packages/control-plane`).
- **Contents:** `src/` with TypeScript source; types aligned with control-plane DTOs but defined as plain interfaces in the SDK (no NestJS/class-validator).
- **Dependencies:** Only standard `fetch` and `WebSocket`; no dependency on the control-plane package.
- **Publish:** Can be published as a separate npm package; GameDemo WebClient consumes via workspace or npm dependency.
- **Branch:** Implement on a new branch in the same repo; no worktree required.

---

## Public API

### Thin Client: `ControlPlaneClient`

- **Constructor:** `new ControlPlaneClient(baseUrl: string, options?: { fetch?: typeof fetch; adminApiKey?: string })`. `baseUrl` is the control-plane HTTP root (e.g. `http://localhost:3000`). Optional `adminApiKey` for future admin auth.
- **Matchmaking:**
  - `enqueue(request: EnqueueRequest): Promise<EnqueueResponse>`
  - `cancel(ticketId: string): Promise<CancelResponse>`
  - `getStatus(ticketId: string): Promise<StatusResponse>`
- **Realtime (optional):**
  - `openRealtimeSocket(ticketId?: string): Promise<RealtimeSocket>`
  - `RealtimeSocket`: `on(event: 'match.assigned' | 'enqueued' | 'error', cb)`, `sendEnqueue(params)`, `close()`. URL is `baseUrl` converted to `ws(s)://` + path `/realtime`, with `?ticketId=xxx` when provided.
- **Admin (read-only):**
  - `getServers(): Promise<ServerListResponse>`
  - `getQueueSummary(): Promise<QueueSummaryResponse>`

### High-Level: `findMatch`

- **Signature:** `findMatch(client: ControlPlaneClient, options: FindMatchOptions): Promise<Assignment>`
- **FindMatchOptions:** Same fields as `EnqueueRequest` (`queueKey`, `members`, `groupSize`, `groupId?`, `region?`, `constraints?`) plus `timeoutMs?: number` (default e.g. 60_000), `signal?: AbortSignal` (for cancellation).
- **Behaviour:**
  1. Call `client.enqueue(options)` to get `ticketId`.
  2. Subscribe via Realtime WebSocket for that `ticketId` (or fallback to polling `getStatus`) until `status === 'assigned'` or timeout/abort.
  3. Resolve with `Assignment` on success; reject on timeout or cancel with a clear error (e.g. `FindMatchTimeoutError` or `AbortError`).
- **Return type:** `Assignment` matches control-plane `AssignmentResult` (`assignmentId`, `matchToken`, `connectUrl`, `landId`, `serverId`, `expiresAt`).

**Exported types:** `EnqueueRequest`, `EnqueueResponse`, `StatusResponse`, `Assignment`, `TicketStatus`, `ServerListResponse`, `QueueSummaryResponse`, etc., for use by WebClient or other callers.

---

## Data Flow & Connecting to the Game

- **Control-plane → SDK:** REST via `fetch`; Realtime via WebSocket; server pushes `{ type: "match.assigned", v: 1, data: { ticketId, assignment } }`; SDK parses and exposes as `Assignment`.
- **Admin:** `GET /v1/admin/servers`, `GET /v1/admin/queue/summary`; if admin later requires API key, SDK sends it in headers via `adminApiKey`.
- **WebClient → Game:**
  1. Create `ControlPlaneClient(controlPlaneBaseUrl)`, call `findMatch(client, { queueKey, members, groupSize, ... })` to get `Assignment`.
  2. **Game connection:** `connectUrl` already includes path and `landId`. Client must append JWT: e.g. `connectUrl + (connectUrl.includes('?') ? '&' : '?') + 'token=' + encodeURIComponent(assignment.matchToken)` to form the final WebSocket URL.
  3. Use existing game client: `useGameClient().connect({ wsUrl: finalWsUrl, playerName, landID: assignment.landId })`. The SDK does **not** connect to the game server; it only returns `Assignment`; the WebClient composes `connectUrl + token` and calls the existing game SDK.

---

## Error Handling & Timeout

- **findMatch timeout:** Reject with a clear message (e.g. "Matchmaking timed out"); optional custom error class (e.g. `FindMatchTimeoutError` or `code: 'FIND_MATCH_TIMEOUT'`) so the UI can show a specific message.
- **Abort:** When `AbortSignal` is aborted, close WS / stop polling and reject with `AbortError` (or `code: 'ABORTED'`).
- **Ticket cancelled/expired:** When status or WS indicates `cancelled` or `expired`, reject with a clear message (e.g. "Ticket cancelled", "Ticket expired").
- **Network / REST errors:** On `fetch` or parse failure, throw (optionally wrap and preserve `cause`); on 4xx/5xx throw with status and body message when available.
- **Thin client:** `enqueue` / `cancel` / `getStatus` throw on non-2xx with status and error body. `openRealtimeSocket` reports connection failure or server close via `RealtimeSocket` `error` event or Promise reject.
- **No retries:** The SDK does not retry or re-enqueue; the caller (WebClient) decides whether to retry.

---

## Testing Strategy

- **Unit (inside `Packages/control-plane-ts-client`):** Mock `fetch` and `WebSocket` (or use MSW); assert request URL/body and response parsing for the thin client. For `findMatch`, mock `ControlPlaneClient` (enqueue returns ticketId, mock Realtime sending `match.assigned` or status returning assigned); assert resolve with correct `Assignment`, and that timeout and abort reject.
- **E2E (optional):** If the repo already has control-plane e2e, add a scenario that runs the real control-plane and exercises the SDK against it, or cover “Find Match → get assignment → connect to game” in GameDemo WebClient e2e. MVP can be unit-only; e2e can follow.
- **Types:** Rely on TypeScript; add light runtime checks for critical DTOs (e.g. presence of required fields on `assignment`) if desired to guard against server contract drift.

---

## Summary

| Item | Choice |
|------|--------|
| Package location | `Packages/control-plane-ts-client/` |
| API | Thin client + `findMatch(client, options) → Promise<Assignment>` |
| Scope | Matchmaking + Realtime WS + Admin read-only |
| Game connection | Caller builds `connectUrl + token` and uses existing game SDK |
| Errors | Timeout / abort / cancelled / expired with clear rejections; no retries in SDK |
| Tests | Unit with mocks; e2e optional in MVP |
