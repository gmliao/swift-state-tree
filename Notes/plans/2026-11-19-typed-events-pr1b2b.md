# #521 PR 1b-2b: the event name checks at registration (EV2, EV3)

**Status:** rev 1, plan only. **Base:** `main` at dd904ef2. The design is #521's plan ([`2026-11-13-typed-events-actions.md`](2026-11-13-typed-events-actions.md)): the EV2 rule in §2.1 ("Checked at registration (EV2)"), EV2 and EV3 in §5's table, N8 (a) in §10, the entry points in §5 and the tests in §7. PR 1b-2a ([`2026-11-19-typed-events-pr1b2a.md`](2026-11-19-typed-events-pr1b2a.md), #638) shipped D10. This note settles what is left of PR 1b-2, and corrects one point of the earlier, unpublished draft of PR 1b-2's note (below).

## Scope

- **EV2:** for each registered server event, client event and action type, the name the wire uses (`_payloadWireName`, `EventPayload.swift:25`) equals the schema's ID for it (`payloadEventName` or `payloadActionName`, `PayloadFieldWriter.swift:83`, :91). A type where they differ is refused at registration.
- **EV3:** when the host passes `eventHashes`, a registered server event whose name has no entry is refused at registration (N8 (a)).

Both are rows in `LandDefinition.validateForRegistration(context:)` (`LandRegistration.swift:97`), reported with the other rows in one `LandRegistrationError`. Neither touches replay, the record codec or the send path.

## What each row catches today's code doesn't

### EV2: a wire name that isn't the schema's name

The wire and the schema name a type by two derivations:
- **The wire** uses `E._payloadWireName`: `AnyServerEvent.init(_:)` and `AnyClientEvent.init(_:)` read it (`EventPayload.swift:109`, :170), and the encoders look the event's hash up by it (`MessagePackTransportMessageEncoder.swift:224`, `TransportMessageEncoder.swift:293`).
- **The schema and the registries** use the runtime rule: `generateEventID` → `payloadEventName` (`SchemaExtractor.swift:218`), so `eventHashes` and the registry's name index (`EventRegistry.swift:99-103`) are keyed by it.

`@Payload` writes `_payloadWireName` as a literal at expansion (`PayloadMacro.swift:65`), by the same rule, and a type without `@Payload` gets the runtime rule (`EventPayload.swift:55`). But `_payloadWireName` is a public protocol requirement: a type can implement it by hand, and an expansion bug would go unseen. Where the two names differ:
- the hash lookup misses, so the event goes out under its string name, which a client built from the schema doesn't know;
- a client event sent under the wire name doesn't find its registry entry.

EV2 makes the two names one fact. With it, the wire name is the registry's name, so the registry's existing checks cover the wire too.

### The correction: two types under one event name are already refused

The unpublished draft of PR 1b-2's note (b84f641c) added a case to EV2: two registered types that share an event name, so that the replay decodes into the last one and a client can't tell them apart. **`main` already refuses that, since #599** (b9e5ac6b, before #632 was reviewed): `LandBuilder` runs `sharedEventNames` over the client and server event registrations (`LandBuilder.swift:182-185`, :237). A shared name is a `LandRegistrationError.duplicateHandlers` entry with both types and the name, and a keeper built without registration refuses it at initialization. Actions sharing a wire name are refused the same way (:112-118). `WireNameCollisionTests` covers both kinds.

The two checks compare one name with different things:
- **#599:** two types, one registry name.
- **EV2:** one type, its wire name against its registry name.

Together they give every registered type a wire name of its own. This PR adds no collision case. Its tests include one land that has both problems, to show that both are reported in one throw.

### EV3: a registered event without a hash

`eventHashes` is the host's opcode table, normally the schema's (`SchemaExtractor.swift:168-171`). An event whose name isn't in it is sent under its string name (the encoders' fallback, cited above), which a client built from that table can't map. EV3 refuses the land at registration instead.
- **No `eventHashes`:** no row. String names are then the configuration.
- **Entries for names the land doesn't register:** allowed. A host can share one table across lands.
- **Client events (`clientEventHashes`):** not in scope. N8 is about what the server sends.

## Entry points

| Entry point | Context it passes after this PR | EV2 | EV3 |
|---|---|---|---|
| `NIOLandHost.register` (`NIOLandHost.swift:382`), and the reevaluation helpers and the monitor land that call it | encoding, recording, and `configuration.eventHashes` (new) | yes | when the configuration has `eventHashes` |
| `LandManager.checkRegistration` (`LandManager.swift:445`), at the first `getOrCreateLand` per land type | encoding, recording, and the manager's `eventHashes` (new) | yes | when the manager has `eventHashes` |
| `ReevaluationEngine.run`, `ReevaluationRunnerImpl.init`, `ReevaluationFeature`'s `recordsForReplay` calls, `SchemaExtractor.extract` | unchanged: no transport | yes | no |
| `LandKeeper` or `TransportAdapter` built directly (tests, benchmarks) | none | no | no |

The replay land registered through `registerWithGenericReplay` gets the live land's configuration and the base's registry (#521 plan §4, M5), so it passes exactly when the base does. The monitor land's `eventHashes` come from its own schema (`ReevaluationFeature.swift:432-437`), so they are complete.

## API

All additive:
- `LandRegistrationContext.eventHashes: [String: Int]?`, with an init parameter that defaults to nil.
- Two `LandRegistrationError` fields, each one line per type:
  - `wireNameMismatches: [String]`: the kind, the type, its wire name and the schema's ID;
  - `serverEventsWithoutHash: [String]`: the event name and the type.
- `description` lists them with the other rows.

**Docs:** in `docs/core/failure-handling.md` § Refused at registration, two rows and the matching `.zh-TW.md` rows.

## Files

- `Sources/SwiftStateTree/Land/LandRegistration.swift`: the context field, the two rows, the error fields.
- `Sources/SwiftStateTreeNIO/NIOLandHost.swift`: passes `eventHashes` (one argument).
- `Sources/SwiftStateTreeTransport/LandManager.swift`: passes `eventHashes` (one argument).
- A new test file in `Tests/SwiftStateTreeTests` and one in `Tests/SwiftStateTreeTransportTests` for the two entry points that throw from the transport layer.
- `docs/core/failure-handling.md` and `.zh-TW.md`.

## The adapter freeze (#555 step 2b)

**This PR touches none of the frozen files:**
- `Sources/SwiftStateTreeTransport/TransportAdapter*.swift`
- `MembershipCoordinator.swift`
- `AdapterErrorMapping.swift`

`LandManager.swift` gains one argument at its registration check, outside the adapter.

**It changes no recorded frame.**
- Both rows only refuse a definition before any land of its type exists. A land that passes runs exactly today's code, so its frames and its record are byte-identical.
- A land the rows refuse never runs, so it has no frames to compare.
- A golden could change only if a harness scenario ran a land that EV2 or EV3 refuses. That means a hand-written wire name, or `eventHashes` missing one of its registered events, given through `LandManager` or `NIOLandHost`. Such a scenario would already be capturing string-named events that a client can't map, so it would be a scenario bug.

**Which order:** either works. Lands before the recording or after it, neither re-records. The planned order is after step 2b records. Its PR then runs the harness's golden comparison in CI like any change on `main`, and an empty diff on every cell is the check. If a cell differs or its land is refused, the PR stops and that scenario goes to the maintainer under the freeze rule (the harness plan's § Freeze). Nothing is re-recorded in this PR.

## Tests

- **EV2, refused:** a server event, a client event and an action type, each with a hand-written `_payloadWireName` that differs from the schema's ID. The refusal must hold at each entry point that runs the row:
  - `NIOLandHost.register` throws, and the path isn't mapped;
  - `getOrCreateLand` throws and creates no land;
  - `ReevaluationEngine.run` and the runner's init throw before a keeper exists;
  - `SchemaExtractor.extract` throws.
- **EV2, passes:** the same types without the override, a type without `@Payload` (the runtime rule) and a generic type (the computed form).
- **EV3, refused:** `eventHashes` missing one registered event, at `NIOLandHost.register` and through `LandManager`. The error names the event and its type.
- **EV3, passes:**
  - `eventHashes` nil;
  - the schema's own table (`SchemaExtractor.extract(...).eventHashes`);
  - a table with extra names.
- **Replay:** a replay land registered through `registerWithGenericReplay` passes and fails as its base does.
- **One throw:** a land with an EV1 type (compressed), an EV2 type, an event without a hash and a #599 shared name reports all four in one `LandRegistrationError`.
- **The examples:** GameDemo and Demo register with their schema's tables. Their tests pass on a clean build (`swift package clean`).
- **Mutants:**
  - the EV2 row off;
  - EV2 comparing the wire name with itself;
  - the EV3 row off;
  - `NIOLandHost` not passing `eventHashes`;
  - `LandManager` not passing `eventHashes`.

## Not in scope

- `clientEventHashes` coverage.
- A hash for an event that is emitted but not registered. The adapter's existing unregistered-event handling applies.
- The value-type redesign (#637) and the verifier's false mismatch (#633).
