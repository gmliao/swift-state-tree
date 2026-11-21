import Foundation
import Logging

/// A small helper for running deterministic re-evaluation from a recorded timeline.
///
/// This is intentionally generic and is meant to be used by demo-specific runners
/// (e.g., `Examples/Demo` and `Examples/GameDemo`) that can import their own land definitions.
public enum ReevaluationEngine {
    private static let diffLogger = Logger(label: "com.swiftstatetree.reevaluation.diff")

    private actor CapturingSink: ReevaluationSink {
        private var eventsByTick: [Int64: [ReevaluationRecordedServerEvent]] = [:]
        private let downstream: (any ReevaluationSink)?

        init(downstream: (any ReevaluationSink)?) { self.downstream = downstream }

        func onEmittedServerEvents(tickId: Int64, events: [ReevaluationRecordedServerEvent]) async {
            eventsByTick[tickId, default: []].append(contentsOf: events)
            if let downstream { await downstream.onEmittedServerEvents(tickId: tickId, events: events) }
        }

        func takeEmittedEvents(for tickId: Int64) -> [ReevaluationRecordedServerEvent] {
            let events = eventsByTick.removeValue(forKey: tickId) ?? []
            return events.sorted { $0.sequence < $1.sequence }
        }
    }

    public struct RunResult: Sendable {
        public let maxTickId: Int64
        public let tickHashes: [Int64: String]
        public let recordedStateHashes: [Int64: String]
        /// Mismatches between recorded and emitted server events (for verification).
        public let serverEventMismatches: [(tickId: Int64, expected: [ReevaluationRecordedServerEvent], actual: [ReevaluationRecordedServerEvent])]
        /// Ticks whose recorded frame carries sequence watermarks.
        ///
        /// Server events of these ticks must match exactly, including `sequence`.
        public let watermarkedTicks: Set<Int64>
        /// Whether the record carries a sync stream. `absent` is never a pass: the sync output
        /// check has nothing to compare.
        public let syncStreamPresence: ReevaluationSyncStreamPresence
        /// The sync-output verification (hashes of every recorded output and seed).
        public let syncOutput: SyncOutputVerification
        /// The check of OnInitialize's events and post-initialize state hash.
        public let initialize: InitializeVerification
        /// For a record older than 2.3 of a land whose state type has the shape #175 changed, or
        /// a record older than 3.3 that holds text that is not NFC (#446),
        /// why a state hash mismatch is not a replay difference; nil otherwise, and then every
        /// mismatch is a failure. Hashes are compared either way: a reader reports a mismatch
        /// with this reason instead of as a failure, and an older record that matches is
        /// verified. Sync-output failures are failures regardless for #175, which changed no
        /// path; for #446 the sync-output digests hash the keys' bytes too, so a mismatch there
        /// is reported as skipped with the reason.
        public let hashIncomparability: String?
        /// What the recorded and replayed state hashes cover, from the record's version.
        public let hashDefinition: ReevaluationHashDefinition
        /// Ticks whose state hash the live run could not compute (recorded as unavailable), with
        /// the recorded reason. They are not compared; a verifier reports them only after every
        /// definite failure. A replay whose conversion throws against a valid recorded hash is a
        /// mismatch, not one of these.
        public let unverifiableStateHashes: [Int64: String]
        /// Whether the record was complete. An incomplete 3.0 record (cut, or closed before every
        /// submission was written) replays every tick but its newest, which is reported here as
        /// unverified, not compared.
        public var recordCompleteness: ReevaluationRecordCompleteness = .complete
        /// Ticks whose recorded passes (a tickless land's, 3.1 on) didn't match the tick's
        /// inputs, with the reason. None of the tick's inputs after the mismatch was found were
        /// applied (it is found before any, unless an input left the queue between passes):
        /// each such tick fails server-event verification.
        public var recordedPassMismatches: [Int64: String] = [:]
        /// The failure that ended the live land (record format 3.4, #535 D9): the replay ended at
        /// its tick, as the live run did. Nil when the land didn't fail or the record is older.
        public var liveFailure: LandFailure?

        /// Verdict on `serverEventMismatches`, decided per tick (see `classifyServerEventMismatches`),
        /// with every tick of `recordedPassMismatches` failed.
        public var serverEventVerification: ServerEventVerification {
            let verdict = ReevaluationEngine.classifyServerEventMismatches(serverEventMismatches, watermarkedTicks: watermarkedTicks)
            guard !recordedPassMismatches.isEmpty else { return verdict }
            var failed = Set(recordedPassMismatches.keys)
            if case .failed(let ticks) = verdict { failed.formUnion(ticks) }
            return .failed(ticks: failed.sorted())
        }
    }

    /// Outcome of the OnInitialize check: the replayed events and post-initialize state hash
    /// against the record's initialize record.
    public enum InitializeVerification: Sendable, Equatable {
        /// The record has no initialize record (older than 2.1); OnInitialize was replayed as
        /// part of tick 0, as before.
        case notRecorded
        case passed
        case failed(reason: String)
        /// The state hash differs, in a record whose hash this build cannot reproduce (#175).
        case notComparable(reason: String)
        /// The live run could not compute the state hash and recorded it as unavailable (#180).
        case unverifiable(reason: String)

        public var summary: String {
            switch self {
            case .notRecorded: return "not recorded"
            case .notComparable(let reason): return "not verified: \(reason)"
            case .unverifiable(let reason): return "unverifiable: \(reason)"
            case .passed: return "verified"
            case .failed(let reason): return "FAILED: \(reason)"
            }
        }
    }

    /// Throws `ReevaluationRecordContentError.malformedEventTarget` for the first recorded event whose
    /// target a live run doesn't write (#641, #729): a malformed target is the record's fault, so it
    /// reports as that, not as a mismatch with the replayed event.
    package static func checkTargets(of events: [ReevaluationRecordedServerEvent]) throws {
        for event in events { _ = try event.target.eventTarget() }
    }

    /// Compares OnInitialize's replayed events and state with the initialize record. A caller
    /// checks the record's targets first (`checkTargets(of:)`), so a malformed one is not
    /// reported as a mismatch.
    package static func verifyInitialize<State: StateNodeProtocol>(
        record: ReevaluationRecordedInitialize?,
        emitted: [ReevaluationRecordedServerEvent],
        state: State,
        hashDefinition: ReevaluationHashDefinition = .fullState,
        hashIncomparability: String? = nil
    ) -> InitializeVerification {
        guard let record else { return .notRecorded }
        if !serverEventsMatch(recorded: record.serverEvents, emitted: emitted) {
            return .failed(reason: "server events differ (recorded \(record.serverEvents.count), replayed \(emitted.count))")
        }
        if let recorded = record.stateHash {
            if isUnavailableHash(recorded) {
                return .unverifiable(reason: "state hash recorded as \(recorded)")
            }
            // A valid recorded hash the replay cannot compute is a divergence.
            guard let replayed = stateHash(state, definition: hashDefinition) else {
                return .failed(reason: "state hash recorded \(recorded), replayed conversion threw")
            }
            if recorded != replayed {
                if let hashIncomparability {
                    return .notComparable(reason: hashIncomparability)
                }
                return .failed(reason: "state hash differs (recorded \(recorded), replayed \(replayed))")
            }
        }
        return .passed
    }

    /// Outcome of server-event verification for a re-evaluation run.
    public enum ServerEventVerification: Sendable, Equatable {
        /// Every compared tick matched exactly.
        case passed
        /// Only ticks without sequence watermarks mismatched, and only in `sequence`.
        /// Older records cannot restore the sequence counter, so this is expected there.
        case passedIgnoringSequence(ticks: [Int64])
        /// At least one tick mismatched in a way that is not explained by missing watermarks:
        /// any mismatch on a watermarked tick, or a content mismatch on any tick.
        case failed(ticks: [Int64])
    }

    /// Decide server-event verification per mismatching tick.
    ///
    /// A watermarked tick fails on any mismatch. A tick without watermarks fails only when the
    /// events differ in something other than `sequence` (count, tick, type, payload or target).
    ///
    /// `expected` holds the events as read from a record: payloads are trees in the record's form.
    /// `actual` holds the replayed events: typed payloads (or trees), which the comparison puts in
    /// the record's form first (#633). Typed payloads on both sides compare in different forms: a
    /// `Date`, `Data` or `URL` field then differs, and a `Float` field can (one that widens to the
    /// same JSON doesn't), so the tick can fail even when only `sequence` differs.
    public static func classifyServerEventMismatches(
        _ mismatches: [(tickId: Int64, expected: [ReevaluationRecordedServerEvent], actual: [ReevaluationRecordedServerEvent])],
        watermarkedTicks: Set<Int64>
    ) -> ServerEventVerification {
        guard !mismatches.isEmpty else { return .passed }
        var failedTicks: [Int64] = []
        var sequenceOnlyTicks: [Int64] = []
        for mismatch in mismatches {
            if !watermarkedTicks.contains(mismatch.tickId),
               serverEventsMatch(recorded: mismatch.expected, emitted: mismatch.actual, compareSequence: false)
            {
                sequenceOnlyTicks.append(mismatch.tickId)
            } else {
                failedTicks.append(mismatch.tickId)
            }
        }
        if !failedTicks.isEmpty {
            return .failed(ticks: failedTicks.sorted())
        }
        return .passedIgnoringSequence(ticks: sequenceOnlyTicks.sorted())
    }
    
    /// Load recorded state JSONL into a [tickId: [String: Any]] dictionary.
    private static func loadRecordedStates(from path: String) throws -> [Int64: [String: Any]] {
        let url = URL(fileURLWithPath: path)
        let content = try String(contentsOf: url, encoding: .utf8)
        var result: [Int64: [String: Any]] = [:]
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tickId = json["tickId"] as? Int64 ?? (json["tickId"] as? Int).map(Int64.init),
                  let stateSnapshot = json["stateSnapshot"] as? [String: Any]
            else { continue }
            result[tickId] = stateSnapshot
        }
        return result
    }

    /// Run a deterministic re-evaluation from a JSON record file.
    ///
    /// Throws `LandRegistrationError` before anything is read or a keeper is built when the
    /// definition fails the encoding-independent registration rows (#535): such a land can't
    /// have run live. Throws `ReevaluationRecordFingerprintError` before the first step for a
    /// record whose schema fingerprint is missing or differs from the definition's (#521 D15).
    /// Throws `ReevaluationRecordContentError.replayTooLong` when the record's last tick + 1 is
    /// past `maxReplayTicks` (#728), when the record is opened.
    public static func run<State: StateNodeProtocol>(
        definition: LandDefinition<State>,
        initialState: State,
        recordFilePath: String,
        services: LandServices = LandServices(),
        sink: (any ReevaluationSink)? = nil,
        exportJsonlPath: String? = nil,
        includeStateHashInExport: Bool = true,
        diffWithPath: String? = nil,
        requiredRecordVersion: String? = nil,
        logger: Logger? = nil,
        maxReplayTicks: Int64 = ReevaluationRecordFile.defaultMaxReplayTicks
    ) async throws -> RunResult {
        try definition.validateForRegistration(context: .encodingIndependent)
        // Opening the source rejects a record older than `minimumSupported`, or one longer than `maxReplayTicks`.
        let source = try ReevaluationRecordFile.openSource(filePath: recordFilePath, maxReplayTicks: maxReplayTicks)
        let metadata = try await source.getMetadata()
        // Without a required version, anything this build reads (2.5+, 3.x); with one, the same
        // rule as the runner and the replay start route (the same major). Checked before
        // anything is replayed.
        let accepted = requiredRecordVersion.map {
            ReevaluationRecordVersion.isCompatible(recorded: metadata.version, required: $0)
        } ?? ReevaluationRecordVersion.isReadable(recorded: metadata.version)
        guard accepted else {
            throw ReevaluationRecordVersionError.incompatible(
                recorded: metadata.version,
                required: requiredRecordVersion ?? ReevaluationRecordVersion.current
            )
        }
        // A record without a schema fingerprint, or with another one, is refused before anything
        // is replayed (#521 D15).
        try ReevaluationSchemaFingerprint.checkRecord(metadata, against: definition)
        // The rows that hold for a land whose records replay (EV8, #521 PR 1b), after the
        // record's own checks: a bad file, version or fingerprint is the more basic error.
        try definition.validateForRegistration(context: LandRegistrationContext(recordsForReplay: true))
        let maxTickId = try await source.getMaxTickId()
        let capturingSink = CapturingSink(downstream: sink)

        // The record decides the RNG seed (`replayRngSeed`): the live land's seed, or the
        // landID-derived one for a record without a seed. A caller's RNG service is replaced, as
        // the hosted replay land does, since any other seed draws other numbers than the live run.
        var resolvedServices = services
        let replaySeed = metadata.replayRngSeed
        if let callerSeed = services.get(DeterministicRngService.self)?.seed, callerSeed != replaySeed {
            logger?.warning(
                "The caller's RNG seed differs from the record's; replaying with the record's seed.",
                metadata: [
                    "landID": .string(metadata.landID),
                    "callerSeed": .stringConvertible(callerSeed),
                    "replaySeed": .stringConvertible(replaySeed),
                ]
            )
        }
        resolvedServices.register(
            DeterministicRngService(seed: replaySeed),
            as: DeterministicRngService.self
        )
        
        let keeper = LandKeeper<State>(
            definition: definition,
            initialState: initialState,
            mode: .reevaluation,
            reevaluationSource: source,
            reevaluationSink: capturingSink,
            services: resolvedServices,
            autoStartLoops: false,
            logger: logger
        )
        await keeper.setLandID(metadata.landID)
        await keeper.awaitInitialization()
        if await keeper.replaySequenceExhausted() { throw ReevaluationRecordContentError.sequenceExhausted }
        let initializeRecord = try await source.getInitializeRecord()
        let stateAfterInitialize = await keeper.currentState()
        let initializeEvents = await capturingSink.takeEmittedEvents(for: -1)
        let hashDefinition = ReevaluationRecordVersion.hashDefinition(recorded: metadata.version)
        let nfcIncomparability = ReevaluationRecordVersion.hashIncomparability(
            recorded: metadata.version, holdsNonNFCText: try await source.getHoldsNonNFCText()
        )
        let hashIncomparability = ReevaluationRecordVersion.hashIncomparability(recorded: metadata.version, stateType: State.self)
            ?? nfcIncomparability
        try checkTargets(of: initializeRecord?.serverEvents ?? [])
        let initialize = verifyInitialize(
            record: initializeRecord,
            emitted: initializeEvents,
            state: stateAfterInitialize,
            hashDefinition: hashDefinition,
            hashIncomparability: hashIncomparability
        )
        // A land without a tick handler is tickless, as the keeper decides it: its record holds
        // its passes in frame 0 (3.1 on), and from 3.4 its sync stream is located by pass, stepped
        // after each replayed pass (#563). Decided from the definition, not the record: a record
        // from before 3.1 has no passes, and its sync stream is skipped as before 3.4.
        let tickless = definition.lifetimeHandlers.tickHandler == nil
        let syncOutputs = SyncOutputDriverBox(SyncOutputReplayDriver<State>(
            metadata: metadata, stream: try await source.getSyncStream(), completeness: try await source.getRecordCompleteness(),
            incomparability: nfcIncomparability, tickless: tickless
        ))
        syncOutputs.driver.begin(
            beforeInitialize: initialState,
            afterInitialize: stateAfterInitialize,
            initializeEvents: initializeEvents
        )
        if tickless {
            await keeper.setReplayPassObserver { ordinal, state in
                let events = await capturingSink.takeEmittedEvents(for: 0)
                syncOutputs.passEvents += events
                syncOutputs.driver.steppedPass(ordinal: ordinal, state: state, events: events)
            }
        }
        // A land that failed live ends at its failure (#535 D9): replay stops at that tick (a
        // tickless land's passes end there too: nothing was applied after it).
        await keeper.setReplayRecordsPassOrdinals(
            !ReevaluationRecordVersion.isBefore3(metadata.version, minor: ReevaluationRecordVersion.passOrdinalMinor)
        )
        // From 3.5 the refused inputs are recorded and compared (#586).
        await keeper.setReplayRecordsRejected(
            !ReevaluationRecordVersion.isBefore3(metadata.version, minor: ReevaluationRecordVersion.rejectedMinor)
        )
        let landFailure = try await source.getLandFailure()
        // Where the failure ended its turn among its inputs, replay ends that tick or pass too.
        if let landFailure, landFailure.failure.position.endsInputs == true {
            await keeper.setReplayFailureEnd(tickId: landFailure.tickId, pass: landFailure.failure.position.pass.map(Int64.init))
        }
        let lastTickId = landFailure.map { min(maxTickId, $0.tickId) } ?? maxTickId
        
        let snapshotEncoder = JSONEncoder()
        snapshotEncoder.outputFormatting = [.sortedKeys]
        
        let exporter: ReevaluationJsonlExporter? = try exportJsonlPath.map { path in
            try ReevaluationJsonlExporter(outputPath: path, overwrite: true)
        }
        
        // Load recorded states for diff comparison if requested.
        let recordedStatesByTick: [Int64: [String: Any]] = try diffWithPath.map { path in
            try loadRecordedStates(from: path)
        } ?? [:]

        var hashes: [Int64: String] = [:]
        var recordedHashes: [Int64: String] = [:]
        var unverifiable: [Int64: String] = [:]
        var serverEventMismatches: [(tickId: Int64, expected: [ReevaluationRecordedServerEvent], actual: [ReevaluationRecordedServerEvent])] = []
        var watermarkedTicks: Set<Int64> = []
        var recordedPassMismatches: [Int64: String] = [:]
        if lastTickId >= 0 {
            for tickId in 0...lastTickId {
                await keeper.stepTickOnce()
                if await keeper.replaySequenceExhausted() { throw ReevaluationRecordContentError.sequenceExhausted }
                let state = await keeper.currentState()

                // The hash the record holds (`hashDefinition`). A conversion that throws makes
                // the tick unverifiable; the replay goes on, as the live run did.
                let snapshot: StateSnapshot
                let stateHash: String
                do {
                    (stateHash, snapshot) = try stateHashAndSnapshot(state, definition: hashDefinition)
                } catch {
                    snapshot = StateSnapshot()
                    stateHash = unavailableHash(error)
                }
                hashes[tickId] = stateHash

                if let recorded = try await source.getStateHash(for: tickId) {
                    recordedHashes[tickId] = recorded
                    // Only a hash the live run could not compute is unverifiable. A valid
                    // recorded hash that the replay cannot reproduce, also because its
                    // conversion throws, is a mismatch like any other.
                    if isUnavailableHash(recorded) {
                        unverifiable[tickId] = "recorded \(recorded)"
                    }
                }

                // Field-level diff against recorded state snapshot when requested.
                if let recordedState = recordedStatesByTick[tickId],
                   let computedData = try? snapshotEncoder.encode(snapshot),
                   let computedState = try? JSONSerialization.jsonObject(with: computedData) as? [String: Any]
                {
                    let diffs = StateSnapshotDiff.compare(recorded: recordedState, computed: computedState)
                    for d in diffs {
                        diffLogger.warning("[tick \(tickId)] DIFF at \(d.path): recorded=\(d.recorded) computed=\(d.computed)")
                    }
                }

                // A tickless pass's events were taken after it (`setReplayPassObserver`).
                let emittedEvents = syncOutputs.takePassEvents() + (await capturingSink.takeEmittedEvents(for: tickId))
                syncOutputs.driver.stepped(tickId: tickId, state: state, events: emittedEvents)
                let recordedEvents = try await source.getServerEvents(for: tickId)
                // Every record this build reads (2.5 on) stores a tick's server events whenever
                // the live run emitted any, so an empty recorded list means none were emitted and
                // is compared like any other: a replay that emits events there fails (#268). A
                // frame without watermarks (a tickless land's) can't restore the sequence counter,
                // so a mismatch there only in sequence is `passedIgnoringSequence`.
                // A tickless frame with passes restores the counter before each pass, so its
                // events are compared exactly too (#321).
                let recordedPasses = try await source.getPasses(for: tickId)
                if try await source.getSequenceWatermarks(for: tickId) != nil || !recordedPasses.isEmpty {
                    watermarkedTicks.insert(tickId)
                }
                if let reason = await keeper.takeRecordedPassMismatch(for: tickId) {
                    recordedPassMismatches[tickId] = reason
                }
                try checkTargets(of: recordedEvents)
                if !serverEventsMatch(recorded: recordedEvents, emitted: emittedEvents) {
                    serverEventMismatches.append((tickId: tickId, expected: recordedEvents, actual: emittedEvents))
                }

                if let exporter {
                    try await exporter.writeTick(
                        tickId: tickId,
                        stateSnapshot: snapshot,
                        stateHash: includeStateHashInExport ? stateHash : nil,
                        serverEvents: emittedEvents
                    )
                }
            }
        }
        
        if let exporter {
            try await exporter.close()
        }
        
        var result = RunResult(
            maxTickId: maxTickId,
            tickHashes: hashes,
            recordedStateHashes: recordedHashes,
            serverEventMismatches: serverEventMismatches,
            watermarkedTicks: watermarkedTicks,
            syncStreamPresence: try await source.getSyncStreamPresence(),
            syncOutput: syncOutputs.driver.finish(),
            initialize: initialize,
            hashIncomparability: hashIncomparability,
            hashDefinition: hashDefinition,
            unverifiableStateHashes: unverifiable
        )
        result.recordCompleteness = try await source.getRecordCompleteness()
        result.recordedPassMismatches = recordedPassMismatches
        result.liveFailure = landFailure?.failure
        return result
    }
    
    /// Compare recorded vs emitted server events: their sequence, tick, type, payload and target.
    ///
    /// A recorded payload is a tree in the record's form, as `CanonicalMessagePack` wrote it (#633):
    /// a `Date` as an ISO string at whole seconds, `Data` as an array of bytes, a `URL` or `Decimal`
    /// in its keyed `Codable` form, a `Float` widened to `Double`. An emitted payload is the replay's
    /// typed value. It is put in the record's form first (`recordForm(_:)`), and the two trees are
    /// compared by their sorted-key JSON, which both record forms (a saved record and its JSON view)
    /// write alike.
    private static func serverEventsMatch(
        recorded: [ReevaluationRecordedServerEvent],
        emitted: [ReevaluationRecordedServerEvent],
        compareSequence: Bool = true
    ) -> Bool {
        guard recorded.count == emitted.count else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for (r, e) in zip(recorded, emitted) {
            guard !compareSequence || r.sequence == e.sequence,
                  r.tickId == e.tickId,
                  r.typeIdentifier == e.typeIdentifier
            else { return false }
            // A payload or target that doesn't encode is a mismatch (A6, #521 PR 1b), never an
            // empty value on both sides, which compared two unencodable payloads equal.
            guard let eTree = try? recordForm(e.payload),
                  let rData = try? encoder.encode(r.payload), let eData = try? encoder.encode(eTree),
                  rData == eData
            else { return false }
            guard let rTarget = try? encoder.encode(r.target), let eTarget = try? encoder.encode(e.target),
                  rTarget == eTarget
            else { return false }
        }
        return true
    }

    /// `payload` in the form a record holds it: written with `CanonicalMessagePack`, as the recorder
    /// writes, and read back as a tree, as the record reader reads. A payload that is already a tree
    /// in that form comes back unchanged.
    static func recordForm(_ payload: AnyCodable) throws -> AnyCodable {
        try CanonicalMessagePack.decode(AnyCodable.self, from: CanonicalMessagePack.encode(payload))
    }

    /// The snapshot a state hash of `definition` covers.
    public static func hashedSnapshot<State: StateNodeProtocol>(
        _ state: State,
        definition: ReevaluationHashDefinition
    ) throws -> StateSnapshot {
        switch definition {
        case .fullState:
            FullStateConversionProbe.record()
            return try state.fullStateSnapshot()
        case .broadcastView:
            return try state.snapshot(for: nil, dirtyFields: nil)
        }
    }

    /// FNV-1a64 over the sorted-keys JSON of `hashedSnapshot`, with that snapshot. Throws when a
    /// value cannot be converted (for the full state, also two map keys that collide as strings).
    public static func stateHashAndSnapshot<State: StateNodeProtocol>(
        _ state: State,
        definition: ReevaluationHashDefinition
    ) throws -> (hash: String, snapshot: StateSnapshot) {
        let snapshot = try hashedSnapshot(state, definition: definition)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        return (DeterministicHash.toHex64(DeterministicHash.fnv1a64(data)), snapshot)
    }

    /// The state hash of `definition`, or nil when the conversion throws.
    public static func stateHash<State: StateNodeProtocol>(
        _ state: State,
        definition: ReevaluationHashDefinition
    ) -> String? {
        try? stateHashAndSnapshot(state, definition: definition).hash
    }

    /// Prefix of a recorded state hash the live run could not compute (`unavailableHash`). A
    /// tick recorded with it, or whose replayed hash cannot be computed, is unverifiable, never a
    /// match.
    public static let unavailableHashPrefix = "unavailable: "

    /// The value recorded in place of a hash whose conversion threw.
    public static func unavailableHash(_ error: any Error) -> String {
        "\(unavailableHashPrefix)\(error)"
    }

    /// Whether a recorded hash value says the hash could not be computed: the 2.4 marker, or
    /// `"error"` as older builds recorded it.
    public static func isUnavailableHash(_ value: String) -> Bool {
        value == "error" || value.hasPrefix(unavailableHashPrefix)
    }

    /// The full-state hash (`ReevaluationHashDefinition.fullState`) and its snapshot, for live
    /// recording; an unconvertible state gives `unavailableHash` and an empty snapshot.
    public static func calculateStateHashAndSnapshot<State: StateNodeProtocol>(_ state: State) -> (hash: String, snapshot: StateSnapshot) {
        do {
            return try stateHashAndSnapshot(state, definition: .fullState)
        } catch {
            return (unavailableHash(error), StateSnapshot())
        }
    }

    /// The full-state hash (`ReevaluationHashDefinition.fullState`), what a 2.4 record holds;
    /// `unavailableHash` when the state cannot be converted.
    public static func calculateStateHash<State: StateNodeProtocol>(_ state: State) -> String {
        calculateStateHashAndSnapshot(state).hash
    }

    /// The broadcast-view hash, what records before 2.4 hold; `"error"` when the state cannot
    /// be converted, as those builds recorded it.
    public static func calculateBroadcastViewHash<State: StateNodeProtocol>(_ state: State) -> String {
        stateHash(state, definition: .broadcastView) ?? "error"
    }
}

/// The sync-output driver and the events taken after each replayed tickless pass, shared with
/// the keeper's pass observer. Used by one replay at a time, from the replay's own awaits only.
private final class SyncOutputDriverBox<State: StateNodeProtocol>: @unchecked Sendable {
    var driver: SyncOutputReplayDriver<State>
    var passEvents: [ReevaluationRecordedServerEvent] = []

    init(_ driver: SyncOutputReplayDriver<State>) {
        self.driver = driver
    }

    func takePassEvents() -> [ReevaluationRecordedServerEvent] {
        defer { passEvents.removeAll() }
        return passEvents
    }
}
