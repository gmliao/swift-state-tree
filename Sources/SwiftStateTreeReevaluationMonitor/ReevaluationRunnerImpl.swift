import Foundation
import Logging
import SwiftStateTree

public enum ReevaluationReplayCompatibilityError: Error, Sendable, CustomNSError, LocalizedError {
    case landTypeMismatch(expected: String, actual: String)
    case schemaMismatch(expectedLandDefinitionID: String, recordedLandDefinitionID: String?)
    case recordVersionMismatch(expectedVersion: String, recordedVersion: String?)
    /// The record's schema fingerprint differs from the definition's (#521 D15). 2002
    /// (`schemaMismatch`) compares the land's `id` string; this compares its fields.
    case schemaFingerprintMismatch(recorded: String, current: String)
    /// The record has no schema fingerprint: it is older than
    /// `ReevaluationRecordVersion.minimumReplayable`, or was written without one (#521 D15).
    case schemaFingerprintMissing(recordedVersion: String?)

    /// The replay error for a record the fingerprint check refused.
    public init(_ error: ReevaluationRecordFingerprintError) {
        switch error {
        case let .mismatch(recorded, current): self = .schemaFingerprintMismatch(recorded: recorded, current: current)
        case let .missing(recordedVersion): self = .schemaFingerprintMissing(recordedVersion: recordedVersion)
        }
    }

    public static var errorDomain: String { "ReevaluationReplayCompatibility" }

    public var errorCode: Int {
        switch self {
        case .landTypeMismatch:
            return 2001
        case .schemaMismatch:
            return 2002
        case .recordVersionMismatch:
            return 2003
        case .schemaFingerprintMismatch:
            return 2004
        case .schemaFingerprintMissing:
            return 2005
        }
    }

    public var errorDescription: String? {
        switch self {
        case .landTypeMismatch(let expected, let actual):
            return "Replay record landType mismatch: expected \(expected), got \(actual)."
        case .schemaMismatch(let expected, let actual):
            let actualValue = actual ?? "nil"
            return "Replay record landDefinitionID mismatch: expected \(expected), got \(actualValue)."
        case .recordVersionMismatch(let expected, let actual):
            let actualValue = actual ?? "nil"
            return "Replay record version mismatch: expected \(expected), got \(actualValue)."
        case let .schemaFingerprintMismatch(recorded, current):
            return "Replay record " + ReevaluationRecordFingerprintError.mismatch(recorded: recorded, current: current).description + "."
        case let .schemaFingerprintMissing(recordedVersion):
            return "Replay record refused: " + ReevaluationRecordFingerprintError.missing(recordedVersion: recordedVersion).description + "."
        }
    }

    public var errorUserInfo: [String: Any] {
        switch self {
        case .landTypeMismatch(let expected, let actual):
            return [
                "code": "LAND_TYPE_MISMATCH",
                "expectedLandType": expected,
                "recordedLandType": actual,
            ]
        case .schemaMismatch(let expected, let actual):
            return [
                "code": "SCHEMA_MISMATCH",
                "expectedLandDefinitionID": expected,
                "recordedLandDefinitionID": actual as Any,
            ]
        case .recordVersionMismatch(let expected, let actual):
            return [
                "code": "RECORD_VERSION_MISMATCH",
                "expectedRecordVersion": expected,
                "recordedRecordVersion": actual as Any,
            ]
        case let .schemaFingerprintMismatch(recorded, current):
            return [
                "code": "RECORD_SCHEMA_FINGERPRINT_MISMATCH",
                "recordedSchemaFingerprint": recorded,
                "currentSchemaFingerprint": current,
            ]
        case let .schemaFingerprintMissing(recordedVersion):
            return [
                "code": "RECORD_SCHEMA_FINGERPRINT_MISSING",
                "recordedRecordVersion": recordedVersion as Any,
                "minimumReplayableVersion": ReevaluationRecordVersion.minimumReplayable,
            ]
        }
    }
}

public actor ConcreteReevaluationRunner<State: StateNodeProtocol>: ReevaluationRunnerProtocol {
    private actor CapturingSink: ReevaluationSink {
        private var eventsByTick: [Int64: [ReevaluationRecordedServerEvent]] = [:]

        func onEmittedServerEvents(tickId: Int64, events: [ReevaluationRecordedServerEvent]) async {
            guard !events.isEmpty else {
                return
            }
            var current = eventsByTick[tickId] ?? []
            current.append(contentsOf: events)
            eventsByTick[tickId] = current
        }

        func takeEmittedEvents(for tickId: Int64) -> [ReevaluationRecordedServerEvent] {
            defer { eventsByTick[tickId] = nil }
            return eventsByTick[tickId] ?? []
        }
    }

    private let keeper: LandKeeper<State>
    /// The base land's definition: its registry resolves each tick's server events (#521 PR 1b).
    private let definition: LandDefinition<State>
    /// A test's faults wrap it (`setFaultsForTesting`), so the reads below are the real calls.
    private var source: any ReevaluationSource
    /// The record's own source, before any test fault wraps it: each `setFaultsForTesting` wraps
    /// this one, so faults don't stack (#646).
    private let recordSource: any ReevaluationSource
    /// Whether the record decodes with the JSON view's allowance, from the record's own source:
    /// a fault wrapper doesn't change the policy (#646).
    private let integralFloats: Bool
    /// What the record's state hashes cover, from its version.
    private let hashDefinition: ReevaluationHashDefinition
    private let snapshotEncoder: JSONEncoder
    /// Encodes the tick's snapshot in place of `snapshotEncoder` when set: a test makes the real
    /// encode call throw (A10).
    private var encodeSnapshot: ((StateSnapshot) throws -> Data)?

    /// Why a state hash mismatch in this record is not a replay difference, if it is not
    /// (`ReevaluationEngine.RunResult.hashIncomparability`): the reasons the engine applies.
    private func hashIncomparability() async throws -> String? {
        let version = try await source.getMetadata().version
        let holdsNonNFCText = try await source.getHoldsNonNFCText()
        return ReevaluationRecordVersion.hashIncomparability(recorded: version, stateType: State.self)
            ?? ReevaluationRecordVersion.hashIncomparability(recorded: version, holdsNonNFCText: holdsNonNFCText)
    }
    private let capturingSink = CapturingSink()

    public let maxTickId: Int64
    /// Whether the record carries a sync stream; `absent` (with the header's reason) is never
    /// reported as a pass.
    public nonisolated let syncStreamPresence: ReevaluationSyncStreamPresence
    private var currentTickId: Int64 = -1
    private let initialState: State
    private var syncOutputDriver: SyncOutputReplayDriver<State>
    private let tickless: Bool
    private let recordsPassOrdinals: Bool
    /// The record is 3.5 or later: replay compares the inputs refused live (#586).
    private let recordsRejected: Bool
    private let landFailure: (tickId: Int64, failure: LandFailure)?
    /// A tickless land's events taken after each replayed pass, for the tick's event check.
    private var passEvents: [ReevaluationRecordedServerEvent] = []
    private var initialize: ReevaluationEngine.InitializeVerification = .notRecorded
    private var prepared = false
    /// The error `prepare()` ended with: a later call throws it again, as it would otherwise return
    /// early and let `step()` run without the initialize check (#741).
    private var prepareFailure: (any Error)?

    public init(
        definition: LandDefinition<State>,
        recordFilePath: String,
        requiredRecordVersion: String? = nil,
        maxReplayTicks: Int64 = ReevaluationRecordFile.defaultMaxReplayTicks
    ) async throws {
        precondition(maxReplayTicks >= 1, "maxReplayTicks must be at least 1")
        self.definition = definition
        source = try ReevaluationRecordFile.openSource(filePath: recordFilePath, maxReplayTicks: maxReplayTicks)
        recordSource = source
        integralFloats = ReevaluationReplayFrame.integralFloats(for: source)
        let metadata = try await source.getMetadata()
        try Self.validateReplayCompatibility(
            metadata: metadata,
            expectedLandType: definition.id,
            expectedLandDefinitionID: definition.id,
            requiredRecordVersion: requiredRecordVersion
        )
        try Self.validateSchemaFingerprint(metadata: metadata, definition: definition)
        // EV8 (#521 PR 1b), after the record's own checks: every recorded server event is
        // decoded in `step()`, so a server event type without a decoder can't replay.
        try definition.validateForRegistration(context: LandRegistrationContext(recordsForReplay: true))
        syncStreamPresence = try await source.getSyncStreamPresence()
        hashDefinition = ReevaluationRecordVersion.hashDefinition(recorded: metadata.version)
        // A land without a tick handler is tickless, as the keeper and the engine decide it: from
        // record 3.4 its sync outputs are located by pass, stepped after each replayed pass (#563).
        tickless = definition.lifetimeHandlers.tickHandler == nil
        recordsPassOrdinals = !ReevaluationRecordVersion.isBefore3(metadata.version, minor: ReevaluationRecordVersion.passOrdinalMinor)
        recordsRejected = !ReevaluationRecordVersion.isBefore3(metadata.version, minor: ReevaluationRecordVersion.rejectedMinor)
        syncOutputDriver = SyncOutputReplayDriver(
            metadata: metadata, stream: try await source.getSyncStream(), completeness: try await source.getRecordCompleteness(),
            incomparability: ReevaluationRecordVersion.hashIncomparability(
                recorded: metadata.version, holdsNonNFCText: try await source.getHoldsNonNFCText()
            ),
            tickless: tickless
        )
        // A land that failed live ends at its failure (#535 D9): the replay stops at that tick.
        let landFailure = try await source.getLandFailure()
        self.landFailure = landFailure
        let recordedMaxTickId = try await source.getMaxTickId()
        maxTickId = landFailure.map { min(recordedMaxTickId, $0.tickId) } ?? recordedMaxTickId

        let initialState = State()
        self.initialState = initialState
        // Note: StateNodeProtocol init() is usually available if defined.
        // We might need an InitialStateFactory if State doesn't have init().
        // But most States have init(). Let's assume passed in or default.
        // Actually LandDefinition doesn't provide init state.
        // We should pass initialState to the init of this class.

        // The record decides the RNG seed (`replayRngSeed`), as in `ReevaluationEngine.run`.
        var resolvedServices = LandServices()
        resolvedServices.register(
            DeterministicRngService(seed: metadata.replayRngSeed),
            as: DeterministicRngService.self
        )

        let logger = Logger(label: "reevaluation-runner")

        keeper = LandKeeper<State>(
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

        snapshotEncoder = JSONEncoder()
        snapshotEncoder.outputFormatting = [.sortedKeys]
    }

    // Auxiliary init to allow passing initial state
    public init(
        definition: LandDefinition<State>,
        initialState: State,
        recordFilePath: String,
        requiredRecordVersion: String? = nil,
        services: LandServices = LandServices(),
        maxReplayTicks: Int64 = ReevaluationRecordFile.defaultMaxReplayTicks
    ) async throws {
        precondition(maxReplayTicks >= 1, "maxReplayTicks must be at least 1")
        self.definition = definition
        source = try ReevaluationRecordFile.openSource(filePath: recordFilePath, maxReplayTicks: maxReplayTicks)
        recordSource = source
        integralFloats = ReevaluationReplayFrame.integralFloats(for: source)
        let metadata = try await source.getMetadata()
        try Self.validateReplayCompatibility(
            metadata: metadata,
            expectedLandType: definition.id,
            expectedLandDefinitionID: definition.id,
            requiredRecordVersion: requiredRecordVersion
        )
        try Self.validateSchemaFingerprint(metadata: metadata, definition: definition)
        // EV8 (#521 PR 1b), after the record's own checks: every recorded server event is
        // decoded in `step()`, so a server event type without a decoder can't replay.
        try definition.validateForRegistration(context: LandRegistrationContext(recordsForReplay: true))
        syncStreamPresence = try await source.getSyncStreamPresence()
        hashDefinition = ReevaluationRecordVersion.hashDefinition(recorded: metadata.version)
        // A land without a tick handler is tickless, as the keeper and the engine decide it: from
        // record 3.4 its sync outputs are located by pass, stepped after each replayed pass (#563).
        tickless = definition.lifetimeHandlers.tickHandler == nil
        recordsPassOrdinals = !ReevaluationRecordVersion.isBefore3(metadata.version, minor: ReevaluationRecordVersion.passOrdinalMinor)
        recordsRejected = !ReevaluationRecordVersion.isBefore3(metadata.version, minor: ReevaluationRecordVersion.rejectedMinor)
        syncOutputDriver = SyncOutputReplayDriver(
            metadata: metadata, stream: try await source.getSyncStream(), completeness: try await source.getRecordCompleteness(),
            incomparability: ReevaluationRecordVersion.hashIncomparability(
                recorded: metadata.version, holdsNonNFCText: try await source.getHoldsNonNFCText()
            ),
            tickless: tickless
        )
        // A land that failed live ends at its failure (#535 D9): the replay stops at that tick.
        let landFailure = try await source.getLandFailure()
        self.landFailure = landFailure
        let recordedMaxTickId = try await source.getMaxTickId()
        maxTickId = landFailure.map { min(recordedMaxTickId, $0.tickId) } ?? recordedMaxTickId

        // Use provided services as base. The record decides the RNG seed (`replayRngSeed`), as
        // in `ReevaluationEngine.run`: a provided RNG service is replaced.
        var resolvedServices = services
        resolvedServices.register(
            DeterministicRngService(seed: metadata.replayRngSeed),
            as: DeterministicRngService.self
        )

        let logger = Logger(label: "reevaluation-runner")

        self.initialState = initialState
        keeper = LandKeeper<State>(
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

        snapshotEncoder = JSONEncoder()
        snapshotEncoder.outputFormatting = [.sortedKeys]
    }

    /// Runs OnInitialize (from the record's initialize record, when it has one) and checks it.
    /// `step()` calls it if the caller did not.
    public func prepare() async throws {
        if let prepareFailure { throw prepareFailure }
        guard !prepared else { return }
        prepared = true
        do {
            try await runPrepare()
        } catch {
            prepareFailure = error
            throw error
        }
    }

    private func runPrepare() async throws {
        await keeper.setReplayRecordsPassOrdinals(recordsPassOrdinals)
        await keeper.setReplayRecordsRejected(recordsRejected)
        // Where the recorded failure ended its turn among its inputs, replay ends that tick or
        // pass the same way (`LandFailurePosition.endsInputs`).
        if let landFailure, landFailure.failure.position.endsInputs == true {
            await keeper.setReplayFailureEnd(tickId: landFailure.tickId, pass: landFailure.failure.position.pass.map(Int64.init))
        }
        if tickless {
            await keeper.setReplayPassObserver { [weak self] ordinal, state in
                await self?.steppedPass(ordinal: ordinal, state: state)
            }
        }
        await keeper.awaitInitialization()
        if await keeper.replaySequenceExhausted() { throw ReevaluationRecordContentError.sequenceExhausted }
        let stateAfterInitialize = await keeper.currentState()
        let initializeEvents = await capturingSink.takeEmittedEvents(for: -1)
        let initializeRecord = try await source.getInitializeRecord()
        try ReevaluationEngine.checkTargets(of: initializeRecord?.serverEvents ?? [])
        initialize = ReevaluationEngine.verifyInitialize(
            record: initializeRecord,
            emitted: initializeEvents,
            state: stateAfterInitialize,
            hashDefinition: hashDefinition,
            hashIncomparability: try await hashIncomparability(),
            refusal: await keeper.replayedInitializeRefusal
        )
        syncOutputDriver.begin(
            beforeInitialize: initialState,
            afterInitialize: stateAfterInitialize,
            initializeEvents: initializeEvents
        )
    }

    /// After a replayed tickless pass: its events, and the sync outputs read after it (#563).
    private func steppedPass(ordinal: Int64, state: State) async {
        let events = await capturingSink.takeEmittedEvents(for: 0)
        passEvents += events
        syncOutputDriver.steppedPass(ordinal: ordinal, state: state, events: events)
    }

    /// The failure that ended the live land, if it failed (record format 3.4); the replay stops
    /// at its tick (`maxTickId`).
    public func liveFailure() -> LandFailure? {
        landFailure?.failure
    }

    /// The sync-output verification of the ticks stepped so far; final once `step()` returned nil.
    public func syncOutputVerification() -> SyncOutputVerification {
        syncOutputDriver.finish()
    }

    /// The OnInitialize check (after `prepare()`).
    public func initializeVerification() -> ReevaluationEngine.InitializeVerification {
        initialize
    }

    public func step() async throws -> ReevaluationStepResult? {
        if currentTickId >= maxTickId {
            return nil
        }

        try await prepare()
        await keeper.stepTickOnce()
        if await keeper.replaySequenceExhausted() { throw ReevaluationRecordContentError.sequenceExhausted }
        // We need to know which tick just executed.
        // keeper.tickId is the current tick ID.
        // stepTickOnce increments tick, then runs.

        // Wait, LandKeeper.stepTickOnce() runs one tick loop iteration.
        // Typically it increments tickId then executes.

        // Let's get current state
        let state = await keeper.currentState()
        // Assuming tickId is accessible via some way, or we track it.
        // keeper doesn't expose public tickId easily?
        // Wait, LandKeeper has no public tickId property?
        // We can track it ourselves since we control the stepping.
        currentTickId += 1
        let tickId = currentTickId
        if tickId == 0 {
            // A record older than 2.1 replays OnInitialize inside tick 0, after the check (#593).
            initialize = ReevaluationEngine.initializeVerdict(
                initialize, afterTickZeroRefusal: await keeper.replayedInitializeRefusal
            )
        }

        // The hash the record holds (`hashDefinition`), the same one `ReevaluationEngine` checks.
        let stateHash: String
        let snapshot: StateSnapshot?
        // A state that can't be converted (a NaN, keys that collide as strings) is unverifiable,
        // never a match (#180): the run goes on, and its frame has no state, with the reason. A
        // replay land refuses that frame (`stateUnavailable`); a monitor-only run doesn't.
        var stateUnavailable: String?
        do {
            let (hash, computed) = try ReevaluationEngine.stateHashAndSnapshot(state, definition: hashDefinition)
            stateHash = hash
            snapshot = computed
        } catch {
            stateHash = ReevaluationEngine.unavailableHash(error)
            snapshot = nil
            stateUnavailable = "the state can't be converted for its hash: \(error)"
        }
        // A snapshot that doesn't encode fails the run (A10, #521 PR 1b): the replay land would
        // have no state to show for the tick.
        var actualStatePayload: AnyCodable?
        if let snapshot {
            do {
                let data = try encodeSnapshot?(snapshot) ?? snapshotEncoder.encode(snapshot)
                actualStatePayload = AnyCodable(String(decoding: data, as: UTF8.self))
            } catch {
                throw ReevaluationReplayResolutionError.stateEncode(tickId: tickId, error: "\(error)")
            }
        }

        // A read error fails the run (A9, #521 PR 1b); a record without a hash for the tick
        // (nil) is unchanged.
        let recordedHash: String?
        do {
            recordedHash = try await source.getStateHash(for: tickId)
        } catch {
            throw ReevaluationReplayResolutionError.recordRead(tickId: tickId, read: "state hash", error: "\(error)")
        }

        // A hash that could not be computed, live or here, is never a match.
        // A tick whose recorded passes didn't match applied none of its inputs (#325): never a
        // match, even where the land records no state hash.
        let recordedPassMismatch = await keeper.takeRecordedPassMismatch(for: tickId)
        let isMatch: Bool
        if recordedPassMismatch != nil {
            isMatch = false
        } else if let recordedHash {
            isMatch = recordedHash == stateHash
                && !ReevaluationEngine.isUnavailableHash(recordedHash)
                && !ReevaluationEngine.isUnavailableHash(stateHash)
        } else {
            isMatch = true
        }
        // A tickless pass's events were taken after it (`steppedPass`).
        let emittedServerEvents = passEvents + (await capturingSink.takeEmittedEvents(for: tickId))
        passEvents.removeAll()
        syncOutputDriver.stepped(tickId: tickId, state: state, events: emittedServerEvents)
        let recordedServerEvents: [ReevaluationRecordedServerEvent]
        do {
            recordedServerEvents = try await source.getServerEvents(for: tickId)
        } catch {
            throw ReevaluationReplayResolutionError.recordRead(tickId: tickId, read: "server events", error: "\(error)")
        }
        // D14 (a′): the tick resolved here, so a record/code mismatch fails the run (EV7, A11).
        // It runs after the tick was applied and the driver stepped: a failure stops only what
        // would be published; nothing is rolled back, and the run's keeper isn't reused.
        let replayFrame = try ReevaluationReplayFrame.resolve(
            tickId: tickId,
            recordedServerEvents: recordedServerEvents,
            emittedServerEvents: emittedServerEvents,
            actualState: actualStatePayload,
            definition: definition,
            integralFloats: integralFloats,
            stateUnavailable: stateUnavailable
        )

        return ReevaluationStepResult(
            tickId: tickId,
            stateHash: stateHash,
            recordedHash: recordedHash,
            isMatch: isMatch,
            actualState: actualStatePayload,
            emittedServerEvents: emittedServerEvents,
            recordedServerEvents: recordedServerEvents,
            recordedPassMismatch: recordedPassMismatch,
            replayFrame: replayFrame
        )
    }

    /// Installs faults for the next steps (tests only), replacing any earlier ones. The record
    /// source is wrapped so its reads throw or find no hash, and the snapshot encode throws. Both
    /// go through the calls `step()` makes, so a `try?` put back on one of them is seen.
    package func setFaultsForTesting(_ faults: ReplayRunnerFaults) {
        source = FaultingReevaluationSource(base: recordSource, faults: faults)
        encodeSnapshot = faults.snapshotEncode ? { _ in throw ReplayRunnerFaults.Injected.snapshotEncode } : nil
    }

    public func setPaused(_: Bool) {
        // Not used in step model
    }

    /// Refuses a record whose schema fingerprint is missing or differs (#521 D15), before the
    /// first step.
    private static func validateSchemaFingerprint(
        metadata: ReevaluationRecordMetadata,
        definition: LandDefinition<State>
    ) throws {
        do {
            try ReevaluationSchemaFingerprint.checkRecord(metadata, against: definition)
        } catch let error as ReevaluationRecordFingerprintError {
            throw ReevaluationReplayCompatibilityError(error)
        }
    }

    private static func validateReplayCompatibility(
        metadata: ReevaluationRecordMetadata,
        expectedLandType: String,
        expectedLandDefinitionID: String,
        requiredRecordVersion: String?
    ) throws {
        if metadata.landType != expectedLandType {
            throw ReevaluationReplayCompatibilityError.landTypeMismatch(
                expected: expectedLandType,
                actual: metadata.landType
            )
        }

        if metadata.landDefinitionID != expectedLandDefinitionID {
            throw ReevaluationReplayCompatibilityError.schemaMismatch(
                expectedLandDefinitionID: expectedLandDefinitionID,
                recordedLandDefinitionID: metadata.landDefinitionID
            )
        }

        if let requiredRecordVersion,
           !ReevaluationRecordVersion.isCompatible(recorded: metadata.version, required: requiredRecordVersion) {
            throw ReevaluationReplayCompatibilityError.recordVersionMismatch(
                expectedVersion: requiredRecordVersion,
                recordedVersion: metadata.version
            )
        }
    }
}

/// Faults a test injects into `ConcreteReevaluationRunner.step()`: the record reads (A9) and the
/// snapshot encode (A10) throw as if the source or the encoder had failed, or the source has no
/// hash for the tick.
package struct ReplayRunnerFaults: Sendable {
    package var stateHashRead = false
    package var serverEventsRead = false
    package var snapshotEncode = false
    /// The source has no hash for the tick (nil), as a land that records none.
    package var stateHashMissing = false

    package init(stateHashRead: Bool = false, serverEventsRead: Bool = false, snapshotEncode: Bool = false, stateHashMissing: Bool = false) {
        self.stateHashRead = stateHashRead
        self.serverEventsRead = serverEventsRead
        self.snapshotEncode = snapshotEncode
        self.stateHashMissing = stateHashMissing
    }

    package enum Injected: Error, Equatable {
        case stateHashRead, serverEventsRead, snapshotEncode
    }
}

/// A record source with `ReplayRunnerFaults`' read faults (tests only); every other read goes to
/// the wrapped source.
struct FaultingReevaluationSource: ReevaluationSource {
    let base: any ReevaluationSource
    let faults: ReplayRunnerFaults

    func getStateHash(for tickId: Int64) async throws -> String? {
        if faults.stateHashRead { throw ReplayRunnerFaults.Injected.stateHashRead }
        if faults.stateHashMissing { return nil }
        return try await base.getStateHash(for: tickId)
    }

    func getServerEvents(for tickId: Int64) async throws -> [ReevaluationRecordedServerEvent] {
        if faults.serverEventsRead { throw ReplayRunnerFaults.Injected.serverEventsRead }
        return try await base.getServerEvents(for: tickId)
    }

    func getMetadata() async throws -> ReevaluationRecordMetadata { try await base.getMetadata() }
    func getActions(for tickId: Int64) async throws -> [ReevaluationRecordedAction] { try await base.getActions(for: tickId) }
    func getClientEvents(for tickId: Int64) async throws -> [ReevaluationRecordedClientEvent] { try await base.getClientEvents(for: tickId) }
    func getLifecycleEvents(for tickId: Int64) async throws -> [ReevaluationRecordedLifecycleEvent] { try await base.getLifecycleEvents(for: tickId) }
    func getMaxTickId() async throws -> Int64 { try await base.getMaxTickId() }
    func getSequenceWatermarks(for tickId: Int64) async throws -> ReevaluationSequenceWatermarks? { try await base.getSequenceWatermarks(for: tickId) }
    func getPasses(for tickId: Int64) async throws -> [ReevaluationRecordedPass] { try await base.getPasses(for: tickId) }
    func getServerInputs(for tickId: Int64) async throws -> [ReevaluationRecordedServerInput] { try await base.getServerInputs(for: tickId) }
    func getRejected(for tickId: Int64) async throws -> [Int64] { try await base.getRejected(for: tickId) }
    func getSyncStream() async throws -> [ReevaluationSyncStreamEntry] { try await base.getSyncStream() }
    func getLandFailure() async throws -> (tickId: Int64, failure: LandFailure)? { try await base.getLandFailure() }
    func getInitializeRecord() async throws -> ReevaluationRecordedInitialize? { try await base.getInitializeRecord() }
    func getRecordCompleteness() async throws -> ReevaluationRecordCompleteness { try await base.getRecordCompleteness() }
    func getHoldsNonNFCText() async throws -> Bool { try await base.getHoldsNonNFCText() }
}
