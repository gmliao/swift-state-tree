// Tests/SwiftStateTreeTransportTests/LandManagerKeeperModeTests.swift
//
// A LandManager's keeper mode resolver is the replay ticket gate: every keeper it creates is live (#612).

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

// MARK: - Test State

@StateNodeBuilder
struct KeeperModeTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var value: Int = 0

    public init() {}
}

/// A nested value with required fields and no `@SnapshotConvertible`: the record schema
/// fingerprint can't list its fields.
struct KeeperModeOpaque: Codable, Sendable {
    let x: Int
}

@Payload
struct KeeperModeOpaqueEvent: ServerEventPayload {
    let inner: KeeperModeOpaque
}

// MARK: - Tests

@Suite("LandManager keeper mode: live keepers and the ticket gate")
struct LandManagerKeeperModeTests {

    @Test("Live land instances use .live keeper mode")
    func liveLandUsesLiveKeeperMode() async throws {
        let landFactory: @Sendable (LandID) -> LandDefinition<KeeperModeTestState> = { landID in
            Land(landID.stringValue, using: KeeperModeTestState.self) {
                Rules {}
            }
        }
        let initialStateFactory: @Sendable (LandID) -> KeeperModeTestState = { _ in
            KeeperModeTestState()
        }

        let manager = LandManager<KeeperModeTestState>(
            landFactory: landFactory,
            initialStateFactory: initialStateFactory,
            keeperModeResolver: nil
        )

        let landID = LandID("test-live:instance-1")
        let definition = landFactory(landID)
        let initialState = initialStateFactory(landID)

        let container = try await manager.getOrCreateLand(
            landID: landID,
            definition: definition,
            initialState: initialState,
            metadata: [:]
        )

        let mode = await container.keeper.getMode()
        #expect(mode == .live)
    }

    @Test("A recording manager refuses a land whose schema fingerprint can't be computed; one that doesn't record creates it (#521 D15)")
    func recordingManagerChecksFingerprint() async throws {
        let landFactory: @Sendable (LandID) -> LandDefinition<KeeperModeTestState> = { landID in
            Land(landID.landType, using: KeeperModeTestState.self) {
                ServerEvents { Register(KeeperModeOpaqueEvent.self) }
                Rules {}
            }
        }
        let landID = LandID(landType: "test-opaque", instanceId: "a")
        let recording = LandManager<KeeperModeTestState>(
            landFactory: landFactory,
            initialStateFactory: { _ in KeeperModeTestState() },
            enableLiveStateHashRecording: true
        )
        let error = try await #require(throws: LandRegistrationError.self) {
            _ = try await recording.getOrCreateLand(
                landID: landID, definition: landFactory(landID), initialState: KeeperModeTestState(), metadata: [:]
            )
        }
        #expect(error.schemaFingerprint == .unbuildableType("KeeperModeOpaque"))
        #expect(await recording.listLands().isEmpty)

        let notRecording = LandManager<KeeperModeTestState>(
            landFactory: landFactory,
            initialStateFactory: { _ in KeeperModeTestState() }
        )
        _ = try await notRecording.getOrCreateLand(
            landID: landID, definition: landFactory(landID), initialState: KeeperModeTestState(), metadata: [:]
        )
        #expect(await notRecording.listLands() == [landID])
    }

    @Test("Invalid replay session descriptor throws ReevaluationReplayError")
    func invalidReplaySessionThrowsReevaluationReplayError() async throws {
        let landFactory: @Sendable (LandID) -> LandDefinition<KeeperModeTestState> = { landID in
            Land(landID.stringValue, using: KeeperModeTestState.self) {
                Rules {}
            }
        }
        let initialStateFactory: @Sendable (LandID) -> KeeperModeTestState = { _ in
            KeeperModeTestState()
        }

        let manager = LandManager<KeeperModeTestState>(
            landFactory: landFactory,
            initialStateFactory: initialStateFactory,
            keeperModeResolver: { landID, _ in
                if landID.landType == "test-replay" {
                    return .invalidReplaySession(message: "Invalid replay session descriptor for instanceId")
                }
                return nil
            }
        )

        let landID = LandID(landType: "test-replay", instanceId: "invalid-instance-id")
        let definition = landFactory(landID)
        let initialState = initialStateFactory(landID)

        do {
            _ = try await manager.getOrCreateLand(
                landID: landID,
                definition: definition,
                initialState: initialState,
                metadata: [:]
            )
            Issue.record("Expected ReevaluationReplayError to be thrown")
        } catch let error as ReevaluationReplayError {
            if case let .invalidSessionDescriptor(message) = error {
                #expect(message == "Invalid replay session descriptor for instanceId")
            } else {
                Issue.record("Expected invalidSessionDescriptor case, got \(error)")
            }
        } catch {
            Issue.record("Expected ReevaluationReplayError, got \(type(of: error)): \(error)")
        }
    }
}
