// Tests/SwiftStateTreeTransportTests/LandManagerFailedInitializationTests.swift
//
// A land whose initialization fails (#104) tears itself down, possibly before the manager
// publishes it. The manager must not store an instance already being torn down: its
// `onLandDestroyed` may have run before it was stored, or never reached the manager.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

@StateNodeBuilder
struct FailedInitTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var value: Int = 0

    public init() {}
}

struct FailedInitOutput: ResolverOutput {
    let value: Int
}

/// Never returns, and ignores cancellation, until the test's gate is released.
struct FailedInitStuckResolver: ContextResolver {
    typealias Output = FailedInitOutput
    static let gate = TestGate()
    static func resolve(ctx: ResolverContext) async throws -> FailedInitOutput {
        await gate.arrive()
        return FailedInitOutput(value: 0)
    }
}

private func stuckInitLand(_ landID: LandID) -> LandDefinition<FailedInitTestState> {
    Land(landID.landType, using: FailedInitTestState.self) {
        Rules {}
        Lifetime {
            OnInitialize(resolvers: FailedInitStuckResolver.self) { (_: inout FailedInitTestState, _: LandContext) in }
        }
    }
}

@Suite("LandManager and a failed initialization", .timeLimit(.minutes(1)))
struct LandManagerFailedInitializationTests {
    @Test("A land torn down before its publication is not stored: the creation fails with landShuttingDown")
    func tornDownBeforePublication() async throws {
        let manager = LandManager<FailedInitTestState>(
            landFactory: { stuckInitLand($0) },
            initialStateFactory: { _ in FailedInitTestState() }
        )
        // Held before publication until the instance's failed initialization started its drain.
        await manager.installHolds(HoldRegistry.at(.publish) {
            while await manager.lastBuiltKeeperForTesting?.isDraining != true { await Task.yield() }
        })
        defer { FailedInitStuckResolver.gate.open() }
        let landID = LandID(landType: "failed-init", instanceId: "room-1")

        // The creation's task: the keeper's eager initialization inherits the 20 ms deadline.
        let error: (any Error)? = await ResolverDeadline.$initOverrideForTesting.withValue(.milliseconds(20)) {
            do {
                _ = try await manager.getOrCreateLand(
                    landID: landID,
                    definition: stuckInitLand(landID),
                    initialState: FailedInitTestState(),
                    metadata: [:]
                )
                return nil
            } catch {
                return error
            }
        }
        guard case .landShuttingDown? = error as? JoinError else {
            Issue.record("Expected landShuttingDown, got \(String(describing: error))")
            return
        }
        #expect(await manager.getLand(landID: landID) == nil, "not stored")
    }
}
