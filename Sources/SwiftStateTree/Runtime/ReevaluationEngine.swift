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
        /// For a record older than 2.3 of a land whose state type has the shape #175 changed,
        /// why a state hash mismatch is not a replay difference; nil otherwise, and then every
        /// mismatch is a failure. Hashes are compared either way: a reader reports a mismatch
        /// with this reason instead of as a failure, and an older record that matches is
        /// verified. Sync-output failures are failures regardless.
        public let hashIncomparability: String?
        /// What the recorded and replayed state hashes cover, from the record's version.
        public let hashDefinition: ReevaluationHashDefinition
        /// Ticks whose state hash could not be computed, live (recorded as unavailable) or in
        /// the replay, with the reason. They are not verified, and a verifier fails on them
        /// instead of comparing the markers.
        public let unverifiableStateHashes: [Int64: String]

        /// Verdict on `serverEventMismatches`, decided per tick (see `classifyServerEventMismatches`).
        public var serverEventVerification: ServerEventVerification {
            ReevaluationEngine.classifyServerEventMismatches(serverEventMismatches, watermarkedTicks: watermarkedTicks)
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

        public var summary: String {
            switch self {
            case .notRecorded: return "not recorded"
            case .notComparable(let reason): return "not verified: \(reason)"
            case .passed: return "verified"
            case .failed(let reason): return "FAILED: \(reason)"
            }
        }
    }

    /// Compares OnInitialize's replayed events and state with the initialize record.
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
            guard !isUnavailableHash(recorded), let replayed = stateHash(state, definition: hashDefinition) else {
                return .failed(reason: "state hash unavailable, not verifiable (recorded \(recorded))")
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
    public static func run<State: StateNodeProtocol>(
        definition: LandDefinition<State>,
        initialState: State,
        recordFilePath: String,
        services: LandServices = LandServices(),
        sink: (any ReevaluationSink)? = nil,
        exportJsonlPath: String? = nil,
        includeStateHashInExport: Bool = true,
        diffWithPath: String? = nil,
        requiredRecordVersion: String = ReevaluationRecordVersion.current,
        logger: Logger? = nil
    ) async throws -> RunResult {
        let source = try JSONReevaluationSource(filePath: recordFilePath)
        let metadata = try await source.getMetadata()
        // Same rule as the runner and the replay start route: same major version only. Checked
        // before anything is replayed.
        guard ReevaluationRecordVersion.isCompatible(recorded: metadata.version, required: requiredRecordVersion) else {
            throw ReevaluationRecordVersionError.incompatible(recorded: metadata.version, required: requiredRecordVersion)
        }
        let maxTickId = try await source.getMaxTickId()
        let capturingSink = CapturingSink(downstream: sink)

        // Ensure RNG seed matches the recorded run (critical for deterministic re-evaluation).
        var resolvedServices = services
        let expectedSeedFromLandID = DeterministicSeed.fromLandID(metadata.landID)
        if let recordedSeed = metadata.rngSeed, recordedSeed != expectedSeedFromLandID {
            logger?.warning(
                "Recorded rngSeed does not match landID-derived seed; using landID-derived seed for deterministic re-evaluation.",
                metadata: [
                    "landID": .string(metadata.landID),
                    "recordedSeed": .stringConvertible(recordedSeed),
                    "expectedSeed": .stringConvertible(expectedSeedFromLandID),
                ]
            )
        }
        resolvedServices.register(
            DeterministicRngService(seed: expectedSeedFromLandID),
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
        let initializeRecord = try await source.getInitializeRecord()
        let stateAfterInitialize = await keeper.currentState()
        let initializeEvents = await capturingSink.takeEmittedEvents(for: -1)
        let hashDefinition = ReevaluationRecordVersion.hashDefinition(recorded: metadata.version)
        let hashIncomparability = ReevaluationRecordVersion.hashIncomparability(recorded: metadata.version, stateType: State.self)
        let initialize = verifyInitialize(
            record: initializeRecord,
            emitted: initializeEvents,
            state: stateAfterInitialize,
            hashDefinition: hashDefinition,
            hashIncomparability: hashIncomparability
        )
        var syncOutputDriver = SyncOutputReplayDriver<State>(metadata: metadata, stream: try await source.getSyncStream())
        syncOutputDriver.begin(
            beforeInitialize: initialState,
            afterInitialize: stateAfterInitialize,
            initializeEvents: initializeEvents
        )
        
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
        if maxTickId >= 0 {
            for tickId in 0...maxTickId {
                await keeper.stepTickOnce()
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
                    if isUnavailableHash(recorded) {
                        unverifiable[tickId] = "recorded \(recorded)"
                    } else if isUnavailableHash(stateHash) {
                        unverifiable[tickId] = "replayed \(stateHash)"
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

                let emittedEvents = await capturingSink.takeEmittedEvents(for: tickId)
                syncOutputDriver.stepped(tickId: tickId, state: state, events: emittedEvents)
                let recordedEvents = try await source.getServerEvents(for: tickId)
                // Frames with sequence watermarks come from records that always store server events,
                // so an empty recorded list is meaningful there and extra replay events are reported.
                // Older frames may lack the server-event field entirely; keep comparing only when
                // something was recorded.
                let frameHasWatermarks = try await source.getSequenceWatermarks(for: tickId) != nil
                if frameHasWatermarks {
                    watermarkedTicks.insert(tickId)
                }
                let shouldCompare = frameHasWatermarks || !recordedEvents.isEmpty
                if shouldCompare, !serverEventsMatch(recorded: recordedEvents, emitted: emittedEvents) {
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
        
        return RunResult(
            maxTickId: maxTickId,
            tickHashes: hashes,
            recordedStateHashes: recordedHashes,
            serverEventMismatches: serverEventMismatches,
            watermarkedTicks: watermarkedTicks,
            syncStreamPresence: try await source.getSyncStreamPresence(),
            syncOutput: syncOutputDriver.finish(),
            initialize: initialize,
            hashIncomparability: hashIncomparability,
            hashDefinition: hashDefinition,
            unverifiableStateHashes: unverifiable
        )
    }
    
    /// Compare recorded vs emitted server events (by JSON encoding for AnyCodable payload equality).
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
            let rData = (try? encoder.encode(r.payload)) ?? Data()
            let eData = (try? encoder.encode(e.payload)) ?? Data()
            if rData != eData { return false }
            let rTarget = (try? encoder.encode(r.target)) ?? Data()
            let eTarget = (try? encoder.encode(e.target)) ?? Data()
            if rTarget != eTarget { return false }
        }
        return true
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

