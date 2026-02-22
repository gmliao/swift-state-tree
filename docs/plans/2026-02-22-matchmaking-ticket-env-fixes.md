# Matchmaking Ticket ID & Env Loading Fixes

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix P1 ticketId collision and env loading order, plus P2 split-role e2e false positive.

**Architecture:** UUID for ticketId (align LocalMatchQueue with ApiMatchQueue); Redis assignment TTL; move env reads to runtime provider factories; split-role e2e via child processes.

**Tech Stack:** NestJS, BullMQ, Redis, Jest

---

## Problem Summary

1. **[P1] ticketId collision:** LocalMatchQueue uses `ticket-${counter}`. After restart, counter resets; new `ticket-1` collides with old Redis assignment → wrong delivery, provisioning e2e fails.
2. **[P1] Env at module load:** `getMatchmakingRole`, `getMatchmakingMinWaitMs`, `getRedisConfig` are called in decorators/top-level before ConfigModule loads .env.
3. **[P2] Split-role e2e false positive:** Test imports AppModule then sets MATCHMAKING_ROLE; module already evaluated with wrong/default role.

---

## Task 1: LocalMatchQueue – Use UUID for ticketId

**Files:**
- Modify: `Packages/control-plane/src/modules/matchmaking/storage/local-match-queue.ts`

**Steps:**
1. Remove `ticketCounter` field.
2. Replace `ticket-${this.ticketCounter}` with `ticket-${crypto.randomUUID().replace(/-/g, '').slice(0, 16)}` (same format as ApiMatchQueue).
3. Run: `cd Packages/control-plane && npm test -- --watchman=false`
4. Commit: `fix(matchmaking): use UUID for LocalMatchQueue ticketId to prevent restart collision`

---

## Task 2: RedisMatchmakingStore – Assignment TTL

**Files:**
- Modify: `Packages/control-plane/src/modules/matchmaking/storage/redis-matchmaking-store.ts`

**Steps:**
1. Change assignment storage from hash `matchmaking:assigned` to per-ticket keys: `matchmaking:assigned:{ticketId}`.
2. Use `redis.set(key, value, 'EX', ttlSeconds)` instead of `hset`.
3. Use `redis.get(key)` instead of `hget`; for `listAllAssigned` (if any) use `keys` or skip (current interface has no listAllAssigned).
4. Add constant `ASSIGNMENT_TTL_SECONDS = 300` (5 min) – assignments are short-lived after match.
5. Run unit tests.
6. Commit: `fix(matchmaking): add TTL to Redis assignment keys for cleanup`

---

## Task 3: MatchmakingModule – Runtime env via useFactory

**Files:**
- Modify: `Packages/control-plane/src/modules/matchmaking/matchmaking.module.ts`

**Steps:**
1. Remove top-level `matchmakingConfig` and `getMatchmakingMinWaitMs()` call.
2. Change `MatchmakingConfig` provider to `useFactory: () => ({ minWaitMs: getMatchmakingMinWaitMs() })`.
3. Change `buildProviders` to accept `role` from a factory – inject via a `MATCHMAKING_ROLE` provider with `useFactory: getMatchmakingRole`.
4. For `controllers`, use a dynamic module or a factory: NestJS doesn't support dynamic controllers easily. Alternative: keep `isApiEnabled(getMatchmakingRole())` but ensure it's called when the module is built – the issue is it's at import time. Use `Module.forRoot()` pattern or a provider that defers. Simpler: use `ConfigService` in a factory. Actually the cleanest is to have a `MatchmakingRole` provider with `useFactory: getMatchmakingRole` and inject it where needed. But `controllers` in @Module is static. We need `ModuleRef` or a different approach.
5. **Simpler approach:** Create `MatchmakingModule.forRoot()` that accepts optional overrides, and reads env inside the factory. For static `controllers`, we can use a conditional: the real fix is ensuring `getMatchmakingRole()` is called *after* ConfigModule has loaded. In NestJS, ConfigModule.forRoot() loads .env when the app bootstraps. The order in AppModule is ConfigModule first. So when MatchmakingModule is imported, ConfigModule should already be in the graph. The issue might be Jest/e2e where .env isn't loaded. The fix: use `ConfigService` from `@nestjs/config` instead of direct `process.env` in env.config. That way we read from ConfigService which is populated after ConfigModule loads. But env.config is a separate layer. Let me try: **use ConfigService in a provider factory** – create a provider that uses ConfigService.get('MATCHMAKING_ROLE') etc. and inject that. The env.config functions would need to be called from within a factory that runs after bootstrap. So we inject ConfigService and call our getters, or we use ConfigService directly. The plan: Add a provider `{ provide: 'MatchmakingConfig', useFactory: (config: ConfigService) => ({ minWaitMs: config.get('MATCHMAKING_MIN_WAIT_MS', 3000) }), inject: [ConfigService] }`. And for role: `{ provide: 'MatchmakingRole', useFactory: (config: ConfigService) => config.get('MATCHMAKING_ROLE', 'all'), inject: [ConfigService] }`. But we need to ensure ConfigModule is imported. It is. And we need to ensure ConfigService has the env - ConfigService reads from process.env and from .env loaded by ConfigModule. The key: ConfigModule.forRoot() loads .env synchronously when the module is initialized. So the first module to be initialized that triggers ConfigModule will load .env. AppModule imports ConfigModule first, so it should work. The problem in e2e: Test.createTestingModule({ imports: [AppModule] }) - does it load ConfigModule? Yes. So .env should load. Unless the test runs with a different cwd or .env is missing. Let me stick to the plan: use useFactory with ConfigService so we're reading at provider instantiation time, which is definitely after module init.
6. Implement: Add ConfigModule import to MatchmakingModule (or rely on global ConfigModule). Use `useFactory` with `inject: [ConfigService]` for MatchmakingConfig and role.
7. For `controllers`, we need the role at module init. The `@Module` decorator is evaluated when the class is loaded. So we can't use injection there. Options: (a) Always register MatchmakingController and have it no-op when role is api-only (check at runtime). (b) Use a dynamic module. (c) Accept that controller registration is static and ensure tests set env before any import. For (a): The controller would need to check role in each handler and return 404 if not api. That's ugly. (d) Use Module.forRoot({ role }) - the test can pass role explicitly. So we'd have MatchmakingModule.forRoot({ role: process.env.MATCHMAKING_ROLE }) - but that still reads at load time. (e) The only way to have dynamic controllers is to use a module that imports a submodule conditionally. We could have MatchmakingApiModule and MatchmakingWorkerModule, and MatchmakingModule imports one or both based on a factory. That's complex. Simpler: **Document that MATCHMAKING_ROLE must be set before Node starts** (e.g. in docker-compose, k8s). For e2e, we use child processes (Task 5) so each process has env set before start. That fixes the e2e. For the module, we can still move MatchmakingConfig and buildProviders to use ConfigService - that helps when ConfigModule loads .env late. The controllers array - we'll leave it as is for now, and fix the e2e with child processes. The report said "move getMatchmakingRole to provider factory" - we can provide a MatchmakingRole token and use it in buildProviders. But buildProviders is called when the module class is defined... No, it's called when the module is being compiled. Let me check - in NestJS, the @Module decorator receives the metadata. The `providers` and `controllers` are passed as static values. So when we write `controllers: isApiEnabled(getMatchmakingRole()) ? [MatchmakingController] : []`, that expression is evaluated when the decorator runs, i.e. when the class is first loaded. So we can't inject anything there. The fix for controllers: we need the test to set process.env.MATCHMAKING_ROLE before importing AppModule. With child processes, each process gets env before any import. So Task 5 fixes that. For Tasks 3 and 4, we focus on: (1) MatchmakingConfig useFactory, (2) BullMQModule useFactory for Redis connection - but BullModule.forRoot expects a static config. We might need BullModule.forRootAsync. Let me check NestJS BullMQ docs... BullModule.forRootAsync({ useFactory: () => ({ connection: getRedisConfig() }), inject: [] }) - that would defer the call. So we need forRootAsync.
8. **Revised Task 3:** MatchmakingModule: use `useFactory` for MatchmakingConfig with ConfigService. For buildProviders role - we need a way to get role at runtime. The providers are instantiated when the module is built. So useFactory for the role-dependent providers. We can have `{ provide: 'MatchmakingRole', useFactory: (c: ConfigService) => c.get('MATCHMAKING_ROLE') || 'all', inject: [ConfigService] }` and then `{ provide: 'MatchQueue', useFactory: (role, ...) => ... }` - but the MatchQueue class selection (ApiMatchQueue vs LocalMatchQueue) is done in useClass. We can't do useClass: X based on async factory easily. We need useFactory that returns the right class or instance. `useFactory: (role, store) => role === 'api' ? new ApiMatchQueue(store, queue) : new LocalMatchQueue(store)` - but that's manual construction, we lose DI for the queue. Better: keep the conditional useClass but get the role from a provider. The problem is useClass is evaluated when the module is built. We could use a custom provider: `{ provide: 'MatchQueue', useFactory: (role, store, queue) => { if (isApiEnabled(role)) return new ApiMatchQueue(store, queue); return new LocalMatchQueue(store); }, inject: ['MatchmakingRole', 'MatchmakingStore', getQueueToken('enqueueTicket')] }`. That works.
9. For controllers - we need to register them conditionally. In NestJS we can use a dynamic module that returns different modules. Or we add a guard that checks role. Simplest: have a RoleGuard that returns 404 when role is not api. And always register the controller. The guard checks at runtime. So we add a guard that injects MatchmakingRole and returns Forbidden or NotFound when not api. That way the controller is always registered but requests are rejected when not in api mode. Actually that might break the test - the test expects the API to work. So when we spawn a child with MATCHMAKING_ROLE=api, the guard would pass. Good.
10. Implement accordingly.

---

## Task 4: BullMQModule & Channels – Defer Redis config

**Files:**
- Modify: `Packages/control-plane/src/infra/bullmq/bullmq.module.ts`
- Modify: `Packages/control-plane/src/infra/channels/redis-match-assigned-channel.service.ts` (if needed)
- Modify: `Packages/control-plane/src/infra/channels/redis-node-inbox-channel.service.ts` (if needed)
- Modify: `Packages/control-plane/src/infra/cluster-directory/redis-cluster-directory.service.ts` (if needed)

**Steps:**
1. BullMQModule: Use `BullModule.forRootAsync({ useFactory: () => ({ connection: getRedisConfig() }), inject: [] })`. This defers getRedisConfig to when the module is initialized.
2. Channels and ClusterDirectory: They already use getRedisConfig in onModuleInit or lazy methods - verify they run after ConfigModule. If they're constructed at module init, they're fine. No change if already lazy.
3. Run tests.
4. Commit: `fix(infra): defer Redis config to runtime in BullMQModule`

---

## Task 5: Split-role e2e – Role isolation

**Files:**
- Modify: `Packages/control-plane/test/matchmaking-split-roles.e2e-spec.ts`

**Outcome:** `jest.resetModules()` + dynamic import breaks NestJS BullMQ (ModuleRef resolution). In-process test cannot achieve true role isolation. Skipped the in-process test; `matchmaking-split-roles-external.e2e-spec.ts` (child processes) provides definitive verification and passes.

---

## Task 6: Verification

**Steps:**
1. `cd Packages/control-plane && npm test -- --watchman=false` – all unit tests pass.
2. `cd Packages/control-plane && npm run test:e2e -- --watchman=false` – all e2e pass (including provisioning).
3. Commit any final fixes.

---

## Notes

- ConfigModule must be imported first in AppModule (already is).
- Assignment TTL of 300s is conservative; clients typically poll and connect within seconds.
- If MatchmakingStore needs `removeAssignedTicket` for explicit cleanup, we can add it later; TTL is sufficient for now.
