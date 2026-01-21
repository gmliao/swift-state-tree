import Foundation
import Logging
import SwiftStateTree

public actor ConcreteReevaluationRunner<State: StateNodeProtocol>: ReevaluationRunnerProtocol {
    private let keeper: LandKeeper<State>
    private let source: JSONReevaluationSource
    private let syncEngine = SyncEngine()
    private let snapshotEncoder: JSONEncoder

    public let maxTickId: Int64
    private var currentTickId: Int64 = -1

    public init(
        definition: LandDefinition<State>,
        recordFilePath: String
    ) async throws {
        source = try JSONReevaluationSource(filePath: recordFilePath)
        let metadata = try await source.getMetadata()
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
            reevaluationSink: nil, // We don't need sink for now, or capturing sink?
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
        services: LandServices = LandServices()
    ) async throws {
        source = try JSONReevaluationSource(filePath: recordFilePath)
        let metadata = try await source.getMetadata()
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
            reevaluationSink: nil,
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
        if let data = try? snapshotEncoder.encode(snapshot) {
            stateHash = DeterministicHash.toHex64(DeterministicHash.fnv1a64(data))
        } else {
            stateHash = "error"
        }

        // Get recorded hash
        let recordedHash = try? await source.getStateHash(for: tickId)

        // Determine match
        let isMatch = (recordedHash == nil) || (recordedHash == stateHash)

        return ReevaluationStepResult(
            tickId: tickId,
            stateHash: stateHash,
            recordedHash: recordedHash,
            isMatch: isMatch
        )
    }

    public func setPaused(_: Bool) {
        // Not used in step model
    }
}
