# GameDemo test lands: visibility and resolver delay/failure (#65)

Two small lands in `Examples/GameDemo` for paths hero-defense does not load: per-player
projection that changes every tick, and action resolvers that are slow or fail. Examples-only;
no library change is planned. If one turns out to be needed, it goes in its own PR.

## 1. Visibility land (`visibility-test`)

**State**
- `entities: [String: VisibleEntity]`, `@Sync(.perPlayer)`. The filter returns the map with only
  the entities whose `visibleTo` contains the player. `VisibleEntity` holds its `position` and
  `heading` (synced) and `visibleTo: Set<PlayerID>` (`@Sync(.serverOnly)` inside the node).
- `viewers: [PlayerID: Viewer]`, `@Sync(.broadcast)`: a fixed position per player, assigned on
  join from a deterministic slot table, plus a `MoveViewer` client event to move it.
- `tickCount` (broadcast), for the tooling.

**Tick** (fixed rate, 50 ms):
- Move every entity on a deterministic path. The path bounces inside the arena with
  `SwiftStateTreeDeterministicMath` (`Position2`, `IVec2`), so entities keep crossing view radii.
- Recompute each entity's `visibleTo`: a squared distance to each viewer against a fixed
  radius, in integer math.
- Entity count and radius come from the land's config (defaults: 40 entities, radius chosen so
  each viewer sees about a quarter of them at a time). Entries and exits happen every few ticks.

**Checks**
- **Projection equals the client's copy:**
  - A CLI scenario (`Tools/CLI/scenarios/game/test-visibility-projection.json`) joins 3 clients
    and runs the existing convergence check several times, each after a run of ticks with
    entries and exits. That's freeze, then each client's reconstructed state against the
    server's projection for that player.
  - Reevaluation record + verify on the same land compares every sync's per-player output with
    the sync-output verifier. That covers "each tick", not just the freeze points.
- **Bytes per sync around view entries:**
  - ws-loadtest gets a scenario `landType` (today it hardcodes `hero-defense`), plus a
    `scenarios/visibility/` scenario.
  - Its report already has update bytes per window. The land also counts entries per tick in a
    broadcast field, so windows with many entries can be told apart.

**Wiring**
- GameServer registers it, at `/game/visibility-test`, with the replay land type when
  reevaluation is on.
- SchemaGen adds it.
- `GameReevaluationFactory` and the server's reevaluation factory accept it. ReevaluationRunner
  `--verify` replays a record of either land; its batch recorder stays Hero Defense only.
- `reevaluation-e2e-game.ts` takes `--land-type`, `--scenario` and `--clients`.

## 2. Resolver land (`resolver-test`)

**State**
- `applied: Int`, `lastResult: String`, `pending: Int` (server-only), and `tickCount`.
- A tick (50 ms) is required: reevaluation replay loads recorded inputs only for tick lands
  (#167).

**Action** `CallService(payload)`. It declares a `ContextResolver` that calls a
`SimulatedExternalService` from `ctx.services`. Configuration comes from env, read once at
startup through EnvHelpers and a `ResolverTestEnvKeys` enum:
- **delay:** fixed or uniform range; the wait uses `safeTaskSleep`;
- **failure rate:** deterministic, from a seeded counter, so a run can be repeated;
- **deadline:** the resolver throws `ResolverDeadlineExceeded` when the simulated call takes
  longer. There is no built-in resolver deadline yet (#104), so it is the resolver's own throw.

The handler applies the result to state.

**What a caller sees on failure** (current path, since #148):
- the service error or the deadline error, and the action is never appended;
- `LandInputRejection.senderSuperseded` if the player re-joined or left while the resolver ran;
- `.landClosed` if the land started draining.

**Optional join resolver** with the same delay/failure settings. Its assertions stay on the
outcome only: the join fails, no player is left behind, and capacity is freed. They don't depend
on whether insertion happens before or after the resolver, which the join-as-turn-input work
changes.

**Checks**
- **Tick rate holds while resolvers are pending:**
  - A CLI scenario fires actions with a delay of several ticks.
  - It reads `tickCount` before and after.
  - It asserts the advance matches wall time within a tolerance: the keeper must not wait on
    resolvers.
- **A failed or timed-out action leaves state unchanged:** the scenario runs with failure rate 1
  and with a deadline shorter than the delay. It asserts the action errors and that `applied`
  and `lastResult` are unchanged, also through a convergence check.
- **Replay matches:** a recorded session that mixes successes and failures replays with matching
  state hashes and a passing sync-output verifier (`test-e2e-game.sh` reevaluation step,
  parameterized by land type).

**Wiring:** the same as the visibility land. ws-loadtest can drive it with `CallService` actions
for a load run where resolvers are pending.

## Order and size

1. Visibility land, server wiring, CLI scenario, reevaluation verify. One commit for the land,
   one for the tooling.
2. Resolver land, the same pieces.
3. ws-loadtest `landType` and the two scenarios.

Each step is an Examples/Tools change, committed to main directly. Each is verified with the
GameDemo build, `test-e2e-game.sh` (all encodings, with reevaluation), and ws-loadtest
`npm test`. The core `swift test` is not affected.

## Decisions (2026-11-05)

- Convergence at the view edges plus the verifier over every sync is enough; no freeze per tick.
  The edge scenario freezes right after an entry, an exit, an entry for one viewer with an exit
  for another, an exit and re-entry within one input and within two back-to-back inputs, and
  an entity swept across two views in one input.
- The visibility scenarios run in `test-e2e-game.sh` in all three encodings; the resolver
  scenarios will run in messagepack only.
- Step 1 found #175: server-only fields of nodes in `[String: X]` / `[PlayerID: X]` maps reach
  clients (also Hero Defense's `players.lastFireTick`). The convergence check and the verifier
  do not catch it, since the projection shares the conversion.

## Open questions (resolved above)

- Is the convergence check at freeze points, plus the verifier over every sync, enough for
  "each tick, the client copy equals the projection", or should the CLI also compare after
  every received frame? That would need the projection per tick, and the admin route freezes
  the land.
- Should `test-e2e-game.sh` run the new scenarios on every CI run, or only in a separate job?
  Each adds one server start per encoding.
