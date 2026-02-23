import Foundation
import Logging
import SwiftStateTree

public enum ReevaluationReplayCompatibilityError: Error, Sendable, CustomNSError, LocalizedError {
    case landTypeMismatch(expected: String, actual: String)
    case schemaMismatch(expectedLandDefinitionID: String, recordedLandDefinitionID: String?)
    case recordVersionMismatch(expectedVersion: String, recordedVersion: String?)

    public static var errorDomain: String { "ReevaluationReplayCompatibility" }

    public var errorCode: Int {
        switch self {
        case .landTypeMismatch:
            return 2001
        case .schemaMismatch:
            return 2002
        case .recordVersionMismatch:
            return 2003
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
    private let source: JSONReevaluationSource
    private let syncEngine = SyncEngine()
    private let snapshotEncoder: JSONEncoder
    private let capturingSink = CapturingSink()

    public let maxTickId: Int64
    private var currentTickId: Int64 = -1

    public init(
        definition: LandDefinition<State>,
        recordFilePath: String,
        requiredRecordVersion: String? = nil
    ) async throws {
        source = try JSONReevaluationSource(filePath: recordFilePath)
        let metadata = try await source.getMetadata()
        try Self.validateReplayCompatibility(
            metadata: metadata,
            expectedLandType: definition.id,
            expectedLandDefinitionID: definition.id,
            requiredRecordVersion: requiredRecordVersion
        )
        maxTickId = try await source.getMaxTickId()

        let initialState = State() // Assuming generic init or we need to pass it
        // Note: StateNodeProtocol init() is usually available if defined.
        // We might need an InitialStateFactory if State doesn't have init().
        // But most States have init(). Let's assume passed in or default.
        // Actually LandDefinition doesn't provide init state.
        // We should pass initialState to the init of this class.

        let services = LandServices()
        // Ensure RNG seed
        let expectedSeedFromLandID = DeterministicSeed.fromLandID(metadata.landID)
        var resolvedServices = services
        resolvedServices.register(
            DeterministicRngService(seed: expectedSeedFromLandID),
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
        services: LandServices = LandServices()
    ) async throws {
        source = try JSONReevaluationSource(filePath: recordFilePath)
        let metadata = try await source.getMetadata()
        try Self.validateReplayCompatibility(
            metadata: metadata,
            expectedLandType: definition.id,
            expectedLandDefinitionID: definition.id,
            requiredRecordVersion: requiredRecordVersion
        )
        maxTickId = try await source.getMaxTickId()

        // Use provided services as base
        var resolvedServices = services
        // Ensure RNG seed
        let expectedSeedFromLandID = DeterministicSeed.fromLandID(metadata.landID)
        resolvedServices.register(
            DeterministicRngService(seed: expectedSeedFromLandID),
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

    public func prepare() async throws {
        // Initialization if needed
    }

    public func step() async throws -> ReevaluationStepResult? {
        if currentTickId >= maxTickId {
            return nil
        }

        // Step forward
        await keeper.stepTickOnce()
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

        // Calculate hash
        let snapshot = try syncEngine.snapshot(from: state, mode: .all)
        let stateHash: String
        var actualStatePayload: AnyCodable?
        if let snapshotData = try? snapshotEncoder.encode(snapshot) {
            stateHash = DeterministicHash.toHex64(DeterministicHash.fnv1a64(snapshotData))
            if let jsonText = String(data: snapshotData, encoding: .utf8) {
                actualStatePayload = AnyCodable(jsonText)
            }
        } else {
            stateHash = "error"
        }

        // Get recorded hash
        let recordedHash = try? await source.getStateHash(for: tickId)

        // Determine match
        let isMatch = (recordedHash == nil) || (recordedHash == stateHash)
        let emittedServerEvents = await capturingSink.takeEmittedEvents(for: tickId)
        let recordedServerEvents = (try? await source.getServerEvents(for: tickId)) ?? []

        return ReevaluationStepResult(
            tickId: tickId,
            stateHash: stateHash,
            recordedHash: recordedHash,
            isMatch: isMatch,
            actualState: actualStatePayload,
            emittedServerEvents: emittedServerEvents,
            recordedServerEvents: recordedServerEvents
        )
    }

    public func setPaused(_: Bool) {
        // Not used in step model
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
           metadata.version != requiredRecordVersion {
            throw ReevaluationReplayCompatibilityError.recordVersionMismatch(
                expectedVersion: requiredRecordVersion,
                recordedVersion: metadata.version
            )
        }
    }
}
