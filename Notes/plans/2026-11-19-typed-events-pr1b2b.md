# #521 PR 1b-2b: the event name checks at registration (EV2, EV3)

**Status:** rev 3, with the code (the 1b-2b code PR). Rev 2 was GO (#653 at 730192e5, merged as bc29cc09), with three shoulds and a nit, folded in here:
- the guarantee is narrowed to definition refusals, and the residue named (§ Replay registrations);
- one context builder (§ Entry points);
- the tests named in should 3, and the host tests' target (§ Tests, § Files);
- the wire claims qualified by message encoding (§ EV3);
- the gate's wording (§ Entry points).

The code PR's review (#656 at bf353a8f, GO on green, four shoulds and a nit) is folded in too:
- the helpers' live check uses the full context (§ Entry points);
- the replay setup stays behind `enabled` (§ Replay registrations);
- EV3's server-only boundary is pinned (§ Tests);
- the generic up-front check's rationale is corrected and the check is tested (§ Replay registrations);
- the nit, `LandRegistrationContext.init`'s new signature, is a PR comment.

Rev 2 folded in rev 1's review (#653 at 3f9d79dc), five shoulds and a nit:
- the fingerprint gate includes the new rows;
- the examples' test is relabelled;
- the replay paths are named;
- the limits are stated;
- the verdict cache's assumption is stated;
- the action collision citation is fixed.

 **Base:** `main` at dd904ef2. The design is #521's plan ([`2026-11-13-typed-events-actions.md`](2026-11-13-typed-events-actions.md)): the EV2 rule in §2.1 ("Checked at registration (EV2)"), EV2 and EV3 in §5's table, N8 (a) in §10, the entry points in §5 and the tests in §7. PR 1b-2a ([`2026-11-19-typed-events-pr1b2a.md`](2026-11-19-typed-events-pr1b2a.md), #638) shipped D10. This note settles what is left of PR 1b-2, and corrects one point of the earlier, unpublished draft of PR 1b-2's note (below).

## Scope

- **EV2:** for each registered server event, client event and action type, the name the wire uses (`_payloadWireName`, `EventPayload.swift:25`) equals the schema's ID for it (`payloadEventName` or `payloadActionName`, `PayloadFieldWriter.swift:83`, :91). A type where they differ is refused at registration.
- **EV3:** when the host passes `eventHashes`, a registered server event whose name has no entry is refused at registration (N8 (a)).

Both are rows in `LandDefinition.validateForRegistration(context:)` (`LandRegistration.swift:97`), reported with the other rows in one `LandRegistrationError`. Neither touches the record codec or the send path. The replay registrations change only in when they check (§ Replay registrations).

**Behaviour change.** Both rows refuse definitions that register today. No land in `Sources/`, `Examples/`, the monitor land, the test fixtures or the goldens is refused (Review checked them at rev 1). Both rows are decisions of #521's plan (EV2, EV3, N8 (a)). The code PR lists both refusals under its behaviour changes.

## What each row catches today's code doesn't

### EV2: a wire name that isn't the schema's name

The wire and the schema name a type by two derivations:
- **The wire** uses `E._payloadWireName`: `AnyServerEvent.init(_:)` and `AnyClientEvent.init(_:)` read it (`EventPayload.swift:109`, :170), and the encoders look the event's hash up by it (`MessagePackTransportMessageEncoder.swift:224`, `TransportMessageEncoder.swift:293`).
- **The schema and the registries** use the runtime rule: `generateEventID` → `payloadEventName` (`SchemaExtractor.swift:218`), so `eventHashes` and the registry's name index (`EventRegistry.swift:99-103`) are keyed by it.

`@Payload` writes `_payloadWireName` as a literal at expansion (`PayloadMacro.swift:65`), by the same rule, and a type without `@Payload` gets the runtime rule (`EventPayload.swift:55`). But `_payloadWireName` is a public protocol requirement: a type can implement it by hand, and an expansion bug would go unseen. Where the two names differ:
- with opcode JSON or MessagePack messages, the hash lookup misses, so the event goes out under its string name, which a client built from the schema doesn't know (plain JSON sends names anyway);
- a client event sent under the wire name doesn't find its registry entry.

EV2 makes the two names one fact. With it, the wire name is the registry's name, so the registry's existing checks cover the wire too.

**How the names are derived, and what EV2 now refuses.**
- The schema's ID is the last dotted component of the type's name, with a trailing `Event` (events) or `Action` (actions) dropped. A type nested in another, `Outer.MoveEvent`, is `Move`.
- A rename therefore changes the ID. A hand-written `_payloadWireName` that keeps the old name, so the wire doesn't change, is exactly what EV2 now refuses.
- That includes actions: action intake matches by the runtime ID (and the type's own names, `sharedActionName`), not by `_payloadWireName`. A kept old name there is a wire name that intake doesn't match.
- The docs row says so: keep the type's name, or rename and regenerate the schema and the clients.

### The correction: two types under one event name are already refused

The unpublished draft of PR 1b-2's note (b84f641c) added a case to EV2: two registered types that share an event name, so that the replay decodes into the last one and a client can't tell them apart. **`main` already refuses that, since #599** (b9e5ac6b, before #632 was reviewed): `LandBuilder` runs `sharedEventNames` over the client and server event registrations (`LandBuilder.swift:182-185`, :237), each within its own namespace. A shared name is a `LandRegistrationError.duplicateHandlers` entry with both types and the name, and a keeper built without registration refuses it at initialization. Two action types an envelope could reach by one name are refused the same way, by `sharedActionName` (:74-95, :218-234). `WireNameCollisionTests` covers both kinds.

The two checks compare one name with different things:
- **#599:** two types, one registry name.
- **EV2:** one type, its wire name against its registry name.

Together they give every registered type a wire name of its own. This PR adds no collision case. Its tests include one land that has both problems, to show that both are reported in one throw.

### EV3: a registered event without a hash

`eventHashes` is the host's opcode table, normally the schema's (`SchemaExtractor.swift:168-171`). With opcode JSON or MessagePack messages, an event whose name isn't in it is sent under its string name (the encoders' fallback, cited above), which a client built from that table can't map. Plain JSON doesn't use the table; EV3 still checks a table that is passed, since the configuration names one. EV3 refuses the land at registration instead.
- **No `eventHashes`:** no row, and that is the right default. It is how every example runs today: DemoServer takes the nil default, and GameServer and ServerLoadTest pass nil. The encoders then send string names, which the SDK accepts.
- **Entries for names the land doesn't register:** allowed. A host can share one table across lands.
- **Client events (`clientEventHashes`):** not in scope. N8 is about what the server sends.

**The limits.**
- **An omitted table looks like nil.** A host that meant to pass a table and didn't gets no check.
- **EV3 checks that a table is complete, not that it is right.** It reads the keys. A foreign table with every key and the wrong opcodes passes, and, with opcode JSON or MessagePack messages, a client built from the land's own schema mis-maps those events. Comparing the values with the land's schema would need the schema at every entry point; that is not in scope.

## Entry points

| Entry point | Context it passes after this PR | EV2 | EV3 |
|---|---|---|---|
| `NIOLandHost.register` (`NIOLandHost.swift:382`), and the reevaluation helpers and the monitor land that call it | `NIOLandServerConfiguration.registrationContext` (new): encoding, recording and `eventHashes`, from the configuration the land registers with | yes | when the configuration has `eventHashes` |
| `LandManager.checkRegistration` (`LandManager.swift:445`), at the first `getOrCreateLand` per land type | encoding, recording, and the manager's `eventHashes` (new) | yes | when the manager has `eventHashes` |
| `ReevaluationEngine.run`, `ReevaluationRunnerImpl.init`, `ReevaluationFeature`'s `recordsForReplay` calls, `SchemaExtractor.extract` | unchanged: no transport | yes | no |
| `LandKeeper` or `TransportAdapter` built directly (tests, benchmarks) | none | no | no |

**The fingerprint gate.** `validateForRegistration` computes the record schema fingerprint only when the other rows hold (`LandRegistration.swift:104`).
- The reason: the fingerprint runs `SchemaExtractor.extract`, which runs `validateForRegistration(.encodingIndependent)` again. A row failing there throws from inside the fingerprint as an error that isn't a `SchemaFingerprintError`, which would replace the outer aggregate.
- EV2 runs in that inner call. When EV2 fails alongside EV3 or EV8, its inner error would replace the outer aggregate and those rows would be lost. When it fails alone, nothing else is lost.
- So the gate's condition gains both new rows: the fingerprint is computed only when EV2 and EV3 also hold. A test pins each condition (§ Tests).

**One context builder.** `register` and the reevaluation helpers' up-front checks read one computed property, `NIOLandServerConfiguration.registrationContext` (`NIOLandHost.swift`). It takes `effectiveTransportEncoding.shouldEncodePayloadAsArray`, `enableLiveStateHashRecording` and `eventHashes`. So a helper checks the replay definition with exactly the context its own `register` will use.
- The replay ticket gate acts when an instance is created, not at registration, so it adds nothing to the context.
- The helpers' check of the live definition, which asks for a fingerprint whatever the configuration says, reads `replayedDefinitionContext`: `registrationContext` with recording forced on. With the bare `LandRegistrationContext(recordsForReplay: true)` it had before, a live land failing EV2 and EV3 threw EV2 alone, before `register` would have reported both.

**The verdict cache.** `LandManager.checkRegistration` caches a verdict per `definition.id` (`LandManager.swift:438`). That is today's design for the existing rows, and the new rows keep it. The cache relies on one assumption, now stated in its doc comment: a land type has one definition per manager. EV2 is a fact about the definition and EV3 about it and the manager's table, and the table is fixed at the manager's init.

## Replay registrations

**`registerWithReevaluationSameLand`** registers one definition twice, live and replay, with the same configuration and so the same table. The replay registration passes exactly when the live one does.

**`registerWithReevaluation` with a different replay definition** (`ReevaluationFeature.swift:121-189`).
- Today it registers the live land and publishes its route (:145), then registers the replay definition (:169) with the live configuration plus the replay ticket gate.
- **Which table:** the live one. The replay land's adapter encodes with that configuration, so the live table is the one its events are sent under, and EV3 checks the replay definition against it.
- **A replay-only event** (registered by the replay definition, not the live one) with no entry in that table would fail EV3 at :169, after the live route is published. Today a throw there leaves the live land registered and serving, with no replay land.
- **The change:** with reevaluation enabled, the overload builds the replay configuration first and checks the replay definition with its `registrationContext`, which carries the live table, before the live land registers. With it off, none of the replay setup runs (the path resolver, `NIOEnvConfig.fromEnvironment()`, the ticket gate), as before. A refusal then throws before anything is registered, so no route is published. The registration of the replay land checks again, as every `register` does.

**`registerWithGenericReplay`** (`ReevaluationFeature.swift:215-290`).
- The alias (`GenericReplayLand.makeLand(basedOn:)`) copies only the base's server-event registry (#521 plan §4, M5) and gets the live configuration. So with the base passing, the alias passes.
- A test of a failing base doesn't reach the alias, so the tests register the alias itself (below).
- It gets the same up-front check, behind `enabled` too: the alias is built once, from `liveLand` alone, before the live registration, checked with the replay configuration's `registrationContext`, and that same value is registered.
- **The alias isn't a subset of the base for every row.** Its event rows are, but it drops the server inputs, so its fingerprint walk differs from the base's (`SchemaFingerprint.swift`, the server-input loop; `ActionEventExtractor.extractEvent` stores a def by the type's short name). A server input with the same short type name as a server event replaces that event's def in the base's walk and can hide a wire-key collision; the alias's walk finds it. With recording on, the base then passes and the alias fails, and without the up-front check the live route would already be published. A test registers such a land (`genericAliasFingerprintRefusedUpFront`), and the check's removal is a killed mutant.

**What can still fail after the live route is published.** The guarantee covers refusals of the live or replay definition only. These failures happen after the live land is registered, as they do today:
- the realm's registration of the replay or monitor land type (an empty or duplicate land type, `LandRealm.swift:115-136`);
- the monitor land's schema extraction or its registration (`ReevaluationFeature.swift`, the monitor block);
- a WebSocket path collision, which overwrites the mapping without throwing.

This PR doesn't change them. Rolling a published route back while connections arrive would be its own race.

**The monitor land's** `eventHashes` come from its own schema, and only when the incoming table is non-nil (`ReevaluationFeature.swift:432-437`). So they are complete.

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
- `Sources/SwiftStateTreeTransport/LandManager.swift`: passes `eventHashes` (one argument), and the cache's doc comment.
- `Sources/SwiftStateTreeNIO/ReevaluationFeature.swift`: the up-front replay-definition check in the custom and generic overloads.
- `Sources/SwiftStateTree/SchemaGen/SchemaFingerprint.swift`: a test-only flag that says whether a definition's fingerprint was computed.
- Tests:
  - `Tests/SwiftStateTreeTests/EventNameRegistrationTests.swift`: the rows, the gate, schema extraction and the engine;
  - `Tests/SwiftStateTreeTransportTests/LandRegistrationEventHashTests.swift`: `LandManager`;
  - `Tests/SwiftStateTreeNIOTests/EventNameHostRegistrationTests.swift`: `NIOLandHost.register` and the reevaluation helpers.
- `docs/core/failure-handling.md` and `.zh-TW.md`.

## The adapter freeze (#555 step 2b)

**This PR touches none of the frozen files:**
- `Sources/SwiftStateTreeTransport/TransportAdapter*.swift`
- `MembershipCoordinator.swift`
- `AdapterErrorMapping.swift`

`LandManager.swift` gains one argument at its registration check, and `ReevaluationFeature.swift` an up-front check. Both are outside the adapter.

**It changes no recorded frame.**
- Both rows only refuse a definition before any land of its type exists. A land that passes runs exactly today's code, so its frames and its record are byte-identical.
- A land the rows refuse never runs, so it has no frames to compare.
- A golden could change only if a harness scenario ran a land that EV2 or EV3 refuses. That means a hand-written wire name, or `eventHashes` missing one of its registered events, given through `LandManager` or `NIOLandHost`. Such a scenario would already be capturing string-named events that a client can't map, so it would be a scenario bug.

**Which order:** either works. Lands before the recording or after it, neither re-records. The planned order is after step 2b records. Its PR then runs the harness's golden comparison in CI like any change on `main`, and an empty diff on every cell is the check. If a cell differs or its land is refused, the PR stops and that scenario goes to the maintainer under the freeze rule (the harness plan's § Freeze). Nothing is re-recorded in this PR.

## Tests

- **EV2, refused:** a server event, a client event and an action type, each with a hand-written `_payloadWireName` that differs from the schema's ID. The refusal must hold at each entry point that runs the row:
  - `NIOLandHost.register` throws, and the path isn't mapped;
  - `getOrCreateLand` throws and creates no land;
  - `ReevaluationEngine.run` throws before it opens the record. The runner's init runs the same row after the record's own checks, and a record of a definition EV2 refuses can't be made through registration, so it isn't tested separately;
  - `SchemaExtractor.extract` throws.
- **EV2, passes:**
  - the same types without the override;
  - a type without `@Payload` (the runtime rule);
  - a plain nested payload (`Outer.MoveEvent`, ID `Move`);
  - a generic event and a generic action (the computed form).
- **EV2, a kept old name:** a renamed event and a renamed action with `_payloadWireName` returning the old name are refused, with both names in the error.
- **EV3, refused:** `eventHashes` missing one registered event, at `NIOLandHost.register` and through `LandManager`. The error names the event and its type.
- **EV3, passes:**
  - `eventHashes` nil;
  - the schema's own table (`SchemaExtractor.extract(...).eventHashes`), passed explicitly to `NIOLandHost.register` and to a `LandManager`;
  - a table with extra names;
  - a complete foreign table with wrong opcodes, which passes: the limit, pinned;
  - a land with a client event and an action, whose table holds only the server events' keys: EV3 checks server events only.
- **Replay:**
  - **`registerWithReevaluation`:** with an opcode encoding and the live schema's table, a replay definition with a replay-only event is refused with that event's missing-hash entry. Neither the live path nor a realm entry for either land type exists afterwards.
  - **The helpers' live check:** a live land failing EV2 and EV3, through `registerWithReevaluationSameLand` and `registerWithGenericReplay`, reports both in one throw and maps nothing.
  - **`registerWithGenericReplay`:**
    - a valid alias with a non-empty table registers;
    - a base whose server input hides a wire-key collision from its own fingerprint is refused through the alias's up-front check, with the live route unpublished;
    - the alias's own registration (`makeLand(basedOn:)` given to `NIOLandHost.register`), with a table missing one of its events, is refused with that event named. This shows the alias runs the row itself.
- **The fingerprint gate:**
  - with recording on, a land failing only EV2 and EV3 reports both in one `LandRegistrationError`, with no fingerprint error and no other error in their place. The four-row test below can't show this, since its EV1 and #599 rows skip the fingerprint;
  - an EV3-only case and an EV2-only case observe whether the fingerprint ran: not while the row fails; for EV3, yes once the table is complete. The EV2 and EV3 case alone would survive deleting either condition, since the other row still skips the fingerprint.
- **One throw:** a land with an EV1 type (compressed), an EV2 type, an event without a hash and a #599 shared name reports all four in one `LandRegistrationError`.
- **The examples:** they keep passing nil `eventHashes`, so EV3 doesn't run for them. Switching them to their schema's tables would move their events from string names to opcodes, a wire change outside this PR. Their tests pass on a clean build (`swift package clean`).
- **Mutants:**
  - the EV2 row off;
  - EV2 comparing the wire name with itself;
  - the EV3 row off;
  - `NIOLandHost` not passing `eventHashes`;
  - `LandManager` not passing `eventHashes`;
  - the fingerprint gate without EV2, and without EV3;
  - the custom overload's up-front replay check removed (the live path is then mapped);
  - the generic overload's up-front check removed (the live path is then mapped);
  - the helpers' live check without the configuration's context.

## Not in scope

- `clientEventHashes` coverage.
- A hash for an event that is emitted but not registered. The adapter's existing unregistered-event handling applies.
- The value-type redesign (#637) and the verifier's false mismatch (#633).
