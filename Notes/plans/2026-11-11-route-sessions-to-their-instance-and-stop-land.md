# Plan: admin DELETE stops the land (#102); detached sessions get a leave and a ticket end (#390)

Status: open. Read on exp/next 2e1792f3. PR A (#390) first, then PR B (#102). The decisions are at the end. Revision 3 (2026-11-11) changes PR B step 1: a stopping instance's wait.

## Where the code is now

#102 was written against a069ea6. Since then #372 and the detach work changed the picture:
- `LandManager.removeLand(landID:)` (LandManager.swift:636) moves the stored instance to `detached[landID][epoch]` (a weak `DetachedKeeper`) and removes the stored entry. The instance keeps running with its players.
- `drainingInstances(of:)` (:392) counts a detached entry only once its `keeper.isDraining`. With auto-create, a join for the ID therefore builds a second instance beside one that still has players. That's #102's split land, still there.
- `NIOLandServer.shutdown()` now really stops lands (close sessions, then `destroyLandsForShutdown`, detached ones included), so #102's last fix item is done.
- The admin route (NIOAdminRoutes.swift:275–293) calls `LandRealm.removeLand` → `NIOLandServer.removeLand` → `LandManager.removeLand` and always answers 200, for an unknown ID too.
- The router binds a session to a land **ID** (`sessionToBoundLandID`, LandRouter.swift:57, set at :716). Five sites resolve it with `landManager.getLand(landID:)`:
  - `onDisconnect` (:289);
  - `closeSessionsForShutdown` (:372);
  - `forwardSyncAck` (:1132);
  - `forwardToTransportAdapter` (:1152);
  - the joined-phase send (:1320).

  The join's own `lookUpLand` (:881) is right to stay by ID. For a joining session, the router already keeps `bound.boundAdapter` (:716–720). This is #390's cause: after a detach, `getLand` returns the replacement or nil, never the instance the session is in.
- `endSessions(ofAbandoned:)` (NIOLandServer.swift:194) takes `ShutdownLandProgress.unfinished: [LandID]` (ShutdownProgress.swift:127) and resolves IDs with `getLand`. It reaches the stored instance only, although `ShutdownLandProgress` already keys by (landID, epoch).

## PR A (#390): resolve a session to its instance, not its ID

Base: exp/next; it merges after exp/next merges into main (#491) and is retargeted to main.

1. **Router binding by instance.**
   - `sessionToBoundLandID` becomes `sessionToBound: [SessionID: BoundLand]`, with `BoundLand { landID, epoch, weak adapter }` captured from the container at bind (:716). This extends `bound.boundAdapter` from the joining phase to the joined one.
   - **The adapter is held weakly**, as `DetachedKeeper` holds its keeper: the router never keeps a destroyed instance (adapter or keeper) alive. `removeSession` returns the `BoundLand`.
   - It is router-only state, read and written in the router's own segments.
2. **"The bound instance has ended"** keeps today's signal. An instance has ended when:
   - its weak adapter is gone, or
   - `LandManager.isLive(epoch:)` says false. The epoch is live while it is stored, or detached with a live keeper that isn't past its destroy: the `detached` entry stays until `onLandDestroyed` runs `dropDetached`, and the stored entry until `removeLand(landID:epoch:)`.

   A forward to an ended instance keeps today's behavior: it answers `joinRoomNotFound` ("Land no longer exists") and clears the binding, so `joinAlreadyJoined` (:584) lets the session rejoin.

   The liveness check is an await on the manager. The router re-checks after it that the binding is still the same epoch (the epoch is the ticket) before it clears it, so a rejoin that bound meanwhile isn't cleared.

   **`isLive(epoch:)` replaces `getLand(landID:)` at each forward site; no forward does both**, so a forward costs no more manager hops than today's single `getLand`. A nil weak adapter answers "ended" with no await; only a live adapter needs `isLive`.
3. **Every forward uses the bound instance:** the five sites above, with the step 2 check.
   - `onDisconnect` and the shutdown's leave forward to the bound adapter, a detached one included. If it has ended, there's nothing to forward, as today.
   - `getSessions(for landID:)` (public, :1346, no callers in Sources or Tests) keeps matching by ID, and its doc says "every instance with this ID".
4. **Abandoned lands by epoch:**
   - `ShutdownLandProgress.unfinished` returns the (landID, epoch) keys;
   - `HostShutdownParticipant.endSessions(ofAbandoned:)` takes epochs (both are package API);
   - `LandManager` resolves an epoch to its adapter, stored or detached: `DetachedKeeper` also holds the adapter weakly, and `ShutdownLand` carries it;
   - `abandonedSessionsEnded` counts instances.
5. **Tests** (GracefulShutdownTests beside :439 and :657, and the router tests), with no timing:
   - **(a) the issue's test.**
     1. Join p1, then `removeLand` (detach).
     2. Create a new stored instance of the same ID, and p2 joins it.
     3. Shut down.

     p1's OnLeave runs on the detached instance before its destroy: the destroy handler sees the leave's effect, through a land probe. p2's runs on the new instance.
   - **(b)** The same, with the detached destroy hung by a `TestGate`. It is abandoned at the deadline, and its session tickets are ended.
   - **(c) Routing after a detach:** p1's action and its sync ack reach the detached instance, not the new one.
   - **(d) An ended instance's session**: p1 is bound, and its instance is destroyed (a forced shutdown of the detached instance). p1's next message gets `joinRoomNotFound`, its binding is cleared, and a rejoin of p1 on the same connection succeeds.
   - **(e) The adapter isn't retained:** after (d)'s destroy, a weak reference to the old adapter is nil once the router drops the binding.
   - **Mutants:**
     - forward by ID again (each of the five sites);
     - no ended check (d fails);
     - a strong adapter (e fails);
     - `unfinished` by ID;
     - `endSessions` resolving only stored instances.

## PR B (#102): DELETE stops the land

Depends on PR A: the per-instance close needs to know which sessions are bound to which instance.

**Phase alignment:**
- The stop's OnLeave goes the way of any disconnect: the adapter's `onDisconnect`, then the membership queue, then the keeper's leave. That's under CLAUDE.md's "join/leave resolvers still re-check by hand" exception, on the existing path, not a new crossing.
- `forceShutdown` is a keeper turn (#382).
- Nothing new runs in the keeper outside a turn.

1. **`LandManager.detachForStop(landID:)`** (package). In one segment:
   - it moves the stored instance to `detached`, marked **stopping**;
   - it returns `(epoch, keeper, adapter)`, or the stopping entry already there for that ID, or nil.

   `drainingInstances(of:)` counts a stopping detached entry, so a join reuses `waitForDrains` with `drainWaitTimeout`, with no second wait:
   - **with auto-create** (`getOrCreateLand`), a join for the ID waits for the old instance's destroy, then builds a fresh one, or fails with `landShuttingDown` at the timeout, as after any slow destroy;
   - **Revision 3, 2026-11-11: the stopping entry's wait is on the epoch's drop.** A draining keeper's wait is `keeper.waitUntilDrained()`, which returns at once while no destruction has started. A stopping instance hasn't started one: its `forceShutdown` comes after its sessions' leaves (step 4). Waiting on its keeper would let a join during the leaves build a second instance beside it. So `waitForDrains` waits for a stopping entry until the manager drops that epoch (`dropDetached`, run by the instance's own `onLandDestroyed`), resumed by the drop. It has the same `drainWaitTimeout` bound, the same `landShuttingDown` at the timeout and the same cancellation; only what is awaited differs. Test (f) holds the join between the detach and `forceShutdown`, and its mutant (no stopping mark, or the keeper's drain wait for a stopping entry) builds the second instance.
     - **The drop always comes:** everything after the mark runs in the stop's own unstructured task (step 4), which the admin request's cancellation can't reach, and nothing in it throws, so `forceShutdown` always runs. That task holds the keeper and the adapter until `forceShutdown` returns, so the weak entry can't be released before its drop, and the instance is never freed without its destroy handlers and save. Test (i).
     - **A drop before the wait isn't missed:** there are awaits between the listing (`drainWaits`) and the wait (the `.drainWait` hold, earlier instances' waits). The wait checks that the epoch is still detached and registers in the same manager segment, and every entry that leaves `detached` resumes its waiters: the dropped epoch, and the entries the released-keeper filter drops with it. The removal and the resumes are one synchronous segment of `dropDetached`, the only removal path; `detachForStop` adds none. The waiters live in a manager dictionary keyed by (landID, epoch), not in the detached entry, so replacing an entry can't lose them. Test (j).
     - **A wait that gives up leaves:** after a timeout or a cancellation, the manager resumes and removes that waiter (or, not registered yet, it returns at once when it registers), so a hung destroy doesn't collect one parked waiter per join attempt.
     - **A destroy that hangs** (a destroy resolver has no deadline) never drops: each join for the ID gets `landShuttingDown` after `drainWaitTimeout`, as for a stored instance whose destroy hangs today;
   - **without auto-create**, `lookUpLand`'s `getLand(landID:)` finds nothing once the ID is detached, so the join is refused as not found and doesn't wait.

   **The public `removeLand(landID:)` is removed** (Q2, the maintainer: remove, don't deprecate):
   - it goes from `LandServerProtocol` (:61), `LandManagerProtocol` (:38), `LandRealm` (:373, and its `removeLandClosure`, which becomes a `stopLandClosure`) and `NIOLandServer` (:109);
   - `LandManager.removeLand(landID:)` (:636) becomes the `package` detach that `detachForStop` builds on, and the tests that detach a land (GracefulShutdownTests :445/:610, MonitorTicketTests :616, ReplayTicketJoinTests :188, LandLifecycleLogTests, LandManagerSingleFlightTests, LandManagerTests, LandReleaseTests) call it by its package name;
   - the test conformers' no-op `removeLand` (NIOAdminDebugStateRoutesTests :171, NIOAdminRoutesReplayStartTests :469, MockLandServer :93) become `stopLand`, and the LandRealmTests cases for `removeLand` (:340, :352) test `stopLand`;
   - there are no callers in `Examples/` or `Tools/`. Comments naming `removeLand(landID:)` (LandManager.swift :124, :739, :755; LandLifecycleLog.swift :14) are updated.
2. **One stop per land ID**. `stopLand` takes the flight by **land ID** (`SingleFlight<LandID, StopLandResult>`, so a DELETE that shares the flight also gets `timedOut`). Whichever DELETE arrives second shares it and returns the same 200:
   - one during the first's flight joins it;
   - one after the detach but before the destroy finds the stopping detached entry (`detachForStop` returns it) and joins its flight;
   - one after the destroy gets 404, unless a fresh instance exists, which it then stops.
3. **`LandRouter.closeSessions(boundTo epoch:, close:)`** (package).
   - In one segment it records `epoch` in `closingEpochs` and snapshots the sessions bound to that epoch. Each is removed with `removeSession`, which ends a session still `.joining`: its attempt is marked ended, so its pending admission is refused (#242).
   - It then runs, per session, **the same per-session body as `closeSessionsForShutdown`**: the adapter's `onDisconnect`, awaited, then `transport.closeSession(_, with: close, awaitingClosed: true)`. That body becomes one shared helper, so the shutdown and the stop can't drift apart.
   - **The bind (:716) checks `closingEpochs` in the same segment as the bind:** a join that got the container before the detach and binds after the snapshot is refused (`landShuttingDown`). Router-only state, so the check and the act are one segment.
4. **`NIOLandServer.stopLand(landID:) async -> StopLandResult`:**
   1. `detachForStop`;
   2. `landRouter.closeSessions(boundTo:)`;
   3. `keeper.forceShutdown()`, which runs the destroy handlers and the save. `onLandDestroyed` → `removeLand(landID:epoch:)` drops the detached entry by epoch, as now.

   Revision 3: steps 1–3 run in the flight's unstructured task, not the request's. The request awaits that task, bounded; its cancellation ends only its own wait. The per-session body doesn't throw (the adapter's `onDisconnect` reports none), so step 3 always runs.

   **The stop is bounded by the host's `shutdownTimeout`** (Q3, decided). Past it, the result is `.stopped(timedOut: true)`, and the destroy and save continue in the background, as an abandoned shutdown destroy does. A DELETE that shares the flight gets the same `StopLandResult`.
5. **API path to the route:**
   - `LandServerProtocol` gets `stopLand(landID:) async -> StopLandResult` as a **plain requirement**, with no default. With `removeLand` gone there's nothing for a default to wrap, and breaking custom conformers is accepted (the maintainer: there are no users).
   - `LandRealm.stopLand` asks the servers listing the ID, and reports stopped if any stopped it.
   - **The DELETE route:**
     - 404 `notFound` for an unknown ID;
     - 200 with `"stopped": true` (and `"timedOut": true` when cut).
   - **Public API in the PR body:**
     - added: `stopLand(landID:)`, `StopLandResult` (a public enum, not frozen: a later case would break exhaustive switches, the question the maintainer is deciding for #507's case), 4014 `landStopped`;
     - removed (maintainer-approved): `removeLand(landID:)` on `LandServerProtocol`, `LandManagerProtocol`, `LandRealm` and `NIOLandServer`;
     - a new requirement on `LandServerProtocol`, which breaks custom conformers, accepted.
6. **Close code**: **4014 `landStopped`**, new in `SessionClose.Code` (Transport.swift); 4013 is reserved for `invalidRowEntry` (C3). 1001 means the server is going away and a client may come back, while 4014 says this room stopped, so don't retry it. ws-loadtest's `on-server-close` and the SDK's `onDisconnect` pass the code through. The close-code lists in `docs/transport` (both languages) get it.
7. **Tests** (NIO host with admin routes, real clients as in GracefulShutdownTests; router-level where the router tests are):
   - **(a)** DELETE with p1 joined:
     - p1's OnLeave ran;
     - p1 is closed with 4014;
     - the destroy handler ran and the save happened;
     - `listLands` lacks L;
     - the keeper's tick stopped.
   - **(b)** A rejoin of L after the DELETE: a fresh epoch, and no frame from the old instance.
   - **(c)** An unknown ID: 404, and nothing changes.
   - **(d)** Two DELETEs, the first held right after its detach (a hold point in `stopLand`): one stop, both 200, and the destroy handler ran once.
   - **(e)** A join racing the stop: held at `LandRouterHoldPoint.afterLand` after it got the container; the DELETE runs to its snapshot; release. The join is refused and not left bound.
   - **(f)** A join held **between the detach and `forceShutdown`**, on a land with auto-create. It waits (its creation is pending), then gets a fresh epoch after the old destroy.
   - **(g)** A session held mid-join (`.joining`, admission pending) at the stop: its join is refused, it is closed with 4014, and no OnJoin runs on the stopped instance.
   - **(h)** OnLeave held (a `TestGate`) past a short `shutdownTimeout` gives 200 with `"timedOut": true`, and a second DELETE sharing the flight gets the same result. After the gate opens, the destroy and save complete.
   - **(i)** (revision 3) The admin request is cancelled while the stop's leaves are held: once released, the instance is destroyed (its destroy handler and save ran), its entry is dropped, and a later join for the ID gets a fresh instance at once.
   - **(j)** (revision 3) A join that listed the stopping instance is held at `.drainWait` while the stop finishes and drops it; released, it builds a fresh instance at once, not a `landShuttingDown` at `drainWaitTimeout` (shortened in the test).
   - **Mutants:**
     - no stopping mark (f builds a second instance);
     - a stopping entry waited for through its keeper's drain (f builds a second instance: the drain hasn't started);
     - the stop's steps in the request's task (i: the cancelled request skips `forceShutdown`; the join gets `landShuttingDown`);
     - the drop wait registers without checking the epoch is still detached (j: `landShuttingDown` at the timeout);
     - the flight keyed by epoch (d: the second DELETE gets 404);
     - no `closingEpochs` check (e);
     - the stop not using the shared per-session body (g);
     - no `forceShutdown`;
     - 200 for an unknown ID;
8. **Docs:** the admin API section (both languages): DELETE stops the land (leaves, 4014, destroy, save), with 404 for an unknown ID. Any mention of `removeLand` in the docs goes (none on exp/next 2e1792f3; re-grep at implementation). The close-code lists add 4014. A Notes/solutions entry if the bind-after-snapshot race carries a lesson: "a per-instance close needs the bind to check the closing set in the same segment".

## Decisions

1. **The close code:** 4014 `landStopped`.
2. ~~`removeLand(landID:)`~~ **Decided: remove it** from the public API, with `stopLand` as a plain requirement (2026-11-11, recorded on #102).
3. **Decided: bound the stop by the host's `shutdownTimeout`**, answering 200 with `"timedOut": true` (B4, test h), the destroy and save continuing in the background (2026-11-11, recorded on #102).

## Solutions consulted

- `2026-11-05-await-resumes-on-stale-state.md`: detach, snapshot and bind check each in one segment; the epoch as the ticket for the clear after the liveness await.
- `2026-11-05-callback-outlives-its-instance-clears-by-key.md`: removal and clearing by epoch.
- `2026-11-05-hold-points-not-timing-in-race-tests.md`: tests B(d)–(h).
