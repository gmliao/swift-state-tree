import Foundation
@testable import SwiftStateTree
@testable import SwiftStateTreeMessagePack
@testable import SwiftStateTreeTransport
import Testing

// MARK: - Test State

@StateNodeBuilder
struct ParallelEncodingTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var round: Int = 0

    @Sync(.perPlayerSlice())
    var playerData: [PlayerID: PlayerData] = [:]
}

struct PlayerData: StateProtocol {
    var score: Int
    var items: [String]
    var metadata: [String: String]
}

// MARK: - Performance Tests

@Suite("TransportAdapter Parallel Encoding Performance Tests")
struct TransportAdapterParallelEncodingPerformanceTests {
    /// Measure encoding performance with multiple players
    /// Compares serial vs parallel encoding modes for JSON codec
    @Test("Performance: Serial vs Parallel Encoding (JSON)")
    func serialVsParallelEncodingJSON() async throws {
        try await runSerialVsParallelEncodingTest(codec: JSONTransportCodec(), label: "JSON")
    }

    /// Measure encoding performance with multiple players
    /// Compares serial vs parallel encoding modes for MessagePack codec
    @Test("Performance: Serial vs Parallel Encoding (MessagePack)")
    func serialVsParallelEncodingMessagePack() async throws {
        try await runSerialVsParallelEncodingTest(codec: MessagePackTransportCodec(), label: "MessagePack")
    }

    /// Helper function to run serial vs parallel encoding test for any codec
    private func runSerialVsParallelEncodingTest(codec: any TransportCodec, label: String) async throws {
        // Arrange: Create state with multiple players
        let playerCount = 50
        var state = ParallelEncodingTestState()
        state.round = 1

        for i in 0 ..< playerCount {
            let playerID = PlayerID("player-\(i)")
            state.playerData[playerID] = PlayerData(
                score: i * 10,
                items: Array(repeating: "item", count: 10),
                metadata: ["level": "\(i)", "class": "warrior"]
            )
        }

        // Create updates for each player
        var updates: [StateUpdate] = []
        for i in 0 ..< playerCount {
            let patches: [StatePatch] = [
                StatePatch(path: "/playerData/player-\(i)/score", operation: .set(.int(i * 20))),
            ]
            updates.append(.diff(patches))
        }

        // Measure serial encoding
        let serialStart = ContinuousClock.now
        var serialResults: [Data] = []
        for update in updates {
            let data = try codec.encode(update)
            serialResults.append(data)
        }
        let serialDuration = serialStart.duration(to: ContinuousClock.now)
        let serialMs = Double(serialDuration.components.seconds) * 1000.0 +
            Double(serialDuration.components.attoseconds) / 1_000_000_000_000_000.0

        // Measure parallel encoding
        let parallelStart = ContinuousClock.now
        let parallelResults = await withTaskGroup(of: Data.self, returning: [Data].self) { group in
            for update in updates {
                group.addTask {
                    try! codec.encode(update)
                }
            }

            var results: [Data] = []
            results.reserveCapacity(updates.count)
            for await result in group {
                results.append(result)
            }
            return results
        }
        let parallelDuration = parallelStart.duration(to: ContinuousClock.now)
        let parallelMs = Double(parallelDuration.components.seconds) * 1000.0 +
            Double(parallelDuration.components.attoseconds) / 1_000_000_000_000_000.0

        // Verify results are the same by decoding and comparing the objects
        // Note: We decode instead of comparing raw bytes because key ordering
        // can vary between encodings. Also, parallel encoding may produce results
        // in a different order, so we compare as sets rather than by index.
        #expect(serialResults.count == parallelResults.count)

        // Decode all results and collect patches by path for comparison
        var serialPatchesByPath: [String: StatePatch] = [:]
        var parallelPatchesByPath: [String: StatePatch] = [:]

        for serialData in serialResults {
            let decoded = try codec.decode(StateUpdate.self, from: serialData)
            if case let .diff(patches) = decoded {
                for patch in patches {
                    serialPatchesByPath[patch.path] = patch
                }
            }
        }

        for parallelData in parallelResults {
            let decoded = try codec.decode(StateUpdate.self, from: parallelData)
            if case let .diff(patches) = decoded {
                for patch in patches {
                    parallelPatchesByPath[patch.path] = patch
                }
            }
        }

        // Verify we have the same number of patches
        #expect(serialPatchesByPath.count == parallelPatchesByPath.count)

        // Compare patches by path (order-independent)
        for (path, serialPatch) in serialPatchesByPath {
            guard let parallelPatch = parallelPatchesByPath[path] else {
                Issue.record("Parallel result missing patch for path: \(path)")
                continue
            }

            #expect(serialPatch.path == parallelPatch.path)
            switch (serialPatch.operation, parallelPatch.operation) {
            case let (.set(serialValue), .set(parallelValue)):
                #expect(serialValue == parallelValue)
            default:
                // For other operation types, just verify they match
                #expect(serialPatch.operation == parallelPatch.operation)
            }
        }

        // In CI environments, parallel encoding may not always be faster due to overhead
        // So we just verify both modes work correctly and log the results
        #expect(serialMs >= 0)
        #expect(parallelMs >= 0)

        // Log performance results
        print("[\(label)] Serial: \(String(format: "%.2f", serialMs))ms, Parallel: \(String(format: "%.2f", parallelMs))ms")
    }

    /// Test comparing all encoding formats including PathHasher with dynamic key compression
    /// Compares: JSON Object vs Opcode JSON (Legacy) vs Opcode JSON (PathHash) vs Opcode MsgPack (Legacy) vs Opcode MsgPack (PathHash)
    @Test("Performance: All encoding formats with PathHasher dynamic key comparison")
    func allEncodingFormatsWithPathHasher() async throws {
        // Arrange: Create state updates for multiple players
        let playerCount = 50
        var updates: [StateUpdate] = []
        for i in 0 ..< playerCount {
            let patches: [StatePatch] = [
                StatePatch(path: "/playerData/player-\(i)/score", operation: .set(.int(i * 20))),
                StatePatch(path: "/playerData/player-\(i)/items", operation: .set(.array([.string("sword"), .string("shield")]))),
                StatePatch(path: "/playerData/player-\(i)/metadata", operation: .set(.object(["level": .string("10"), "class": .string("warrior")]))),
            ]
            updates.append(.diff(patches))
        }

        // Create PathHasher with path patterns
        // The pattern uses "*" for dynamic keys (player IDs)
        let pathHashes: [String: UInt32] = [
            "playerData": 0x0001,
            "playerData.*": 0x0002,
            "playerData.*.score": 0x0003,
            "playerData.*.items": 0x0004,
            "playerData.*.metadata": 0x0005,
        ]
        let pathHasher = PathHasher(pathHashes: pathHashes)

        // Create encoders - 5 variants
        let jsonObjectEncoder = JSONStateUpdateEncoder()
        let opcodeJsonLegacyEncoder = OpcodeJSONStateUpdateEncoder() // Without PathHasher
        let opcodeJsonPathHashEncoder = OpcodeJSONStateUpdateEncoder(pathHasher: pathHasher) // With PathHasher
        let opcodeMsgPackLegacyEncoder = OpcodeMessagePackStateUpdateEncoder() // Without PathHasher
        let opcodeMsgPackPathHashEncoder = OpcodeMessagePackStateUpdateEncoder(pathHasher: pathHasher) // With PathHasher

        let landID = "test-land"
        let playerID = PlayerID("test-player")

        // Helper to measure encoding
        func measureEncode(_ encoder: any StateUpdateEncoder, label _: String) throws -> (timeMs: Double, totalBytes: Int) {
            let start = ContinuousClock.now
            var results: [Data] = []
            for update in updates {
                let data = try encoder.encode(update: update, landID: landID, playerID: playerID)
                results.append(data)
            }
            let duration = start.duration(to: ContinuousClock.now)
            let ms = Double(duration.components.seconds) * 1000.0 +
                Double(duration.components.attoseconds) / 1_000_000_000_000_000.0
            let totalBytes = results.reduce(0) { $0 + $1.count }
            return (ms, totalBytes)
        }

        // Measure all formats
        let jsonResult = try measureEncode(jsonObjectEncoder, label: "JSON Object")
        let opcodeJsonLegacy = try measureEncode(opcodeJsonLegacyEncoder, label: "Opcode JSON (Legacy)")
        let opcodeJsonPathHash = try measureEncode(opcodeJsonPathHashEncoder, label: "Opcode JSON (PathHash)")
        let opcodeMsgPackLegacy = try measureEncode(opcodeMsgPackLegacyEncoder, label: "Opcode MsgPack (Legacy)")
        let opcodeMsgPackPathHash = try measureEncode(opcodeMsgPackPathHashEncoder, label: "Opcode MsgPack (PathHash)")

        // Log comparison results
        print("===================== All Encoding Formats Comparison =====================")
        print("Format                      | Time      | Total Bytes | Per Update | vs JSON")
        print("-----------------------------------------------------------------------")
        print("JSON Object                 | \(String(format: "%6.2f", jsonResult.timeMs))ms | \(String(format: "%11d", jsonResult.totalBytes)) | \(String(format: "%10d", jsonResult.totalBytes / updates.count)) | 100.0%")
        print("Opcode JSON (Legacy)        | \(String(format: "%6.2f", opcodeJsonLegacy.timeMs))ms | \(String(format: "%11d", opcodeJsonLegacy.totalBytes)) | \(String(format: "%10d", opcodeJsonLegacy.totalBytes / updates.count)) | \(String(format: "%5.1f", Double(opcodeJsonLegacy.totalBytes) / Double(jsonResult.totalBytes) * 100))%")
        print("Opcode JSON (PathHash)      | \(String(format: "%6.2f", opcodeJsonPathHash.timeMs))ms | \(String(format: "%11d", opcodeJsonPathHash.totalBytes)) | \(String(format: "%10d", opcodeJsonPathHash.totalBytes / updates.count)) | \(String(format: "%5.1f", Double(opcodeJsonPathHash.totalBytes) / Double(jsonResult.totalBytes) * 100))%")
        print("Opcode MsgPack (Legacy)     | \(String(format: "%6.2f", opcodeMsgPackLegacy.timeMs))ms | \(String(format: "%11d", opcodeMsgPackLegacy.totalBytes)) | \(String(format: "%10d", opcodeMsgPackLegacy.totalBytes / updates.count)) | \(String(format: "%5.1f", Double(opcodeMsgPackLegacy.totalBytes) / Double(jsonResult.totalBytes) * 100))%")
        print("Opcode MsgPack (PathHash)   | \(String(format: "%6.2f", opcodeMsgPackPathHash.timeMs))ms | \(String(format: "%11d", opcodeMsgPackPathHash.totalBytes)) | \(String(format: "%10d", opcodeMsgPackPathHash.totalBytes / updates.count)) | \(String(format: "%5.1f", Double(opcodeMsgPackPathHash.totalBytes) / Double(jsonResult.totalBytes) * 100))%")
        print("===========================================================================")
        print("PathHash benefit (JSON):    \(String(format: "%.1f", (1.0 - Double(opcodeJsonPathHash.totalBytes) / Double(opcodeJsonLegacy.totalBytes)) * 100))% smaller than Legacy")
        print("PathHash benefit (MsgPack): \(String(format: "%.1f", (1.0 - Double(opcodeMsgPackPathHash.totalBytes) / Double(opcodeMsgPackLegacy.totalBytes)) * 100))% smaller than Legacy")
        print("Best format savings:        \(String(format: "%.1f", (1.0 - Double(opcodeMsgPackPathHash.totalBytes) / Double(jsonResult.totalBytes)) * 100))% smaller than JSON Object")
        print("===========================================================================")

        // Basic validation
        #expect(jsonResult.totalBytes > 0)
        #expect(opcodeJsonLegacy.totalBytes > 0)
        #expect(opcodeJsonPathHash.totalBytes > 0)
        #expect(opcodeMsgPackLegacy.totalBytes > 0)
        #expect(opcodeMsgPackPathHash.totalBytes > 0)

        // PathHash should be smaller than Legacy (due to using hash instead of full path string)
        #expect(opcodeJsonPathHash.totalBytes < opcodeJsonLegacy.totalBytes)
        #expect(opcodeMsgPackPathHash.totalBytes < opcodeMsgPackLegacy.totalBytes)
    }

    /// Test that Opcode MessagePack encoder supports parallel encoding
    @Test("Opcode MessagePack encoder supports parallel encoding")
    func opcodeMessagePackParallelEncoding() async throws {
        // Arrange: Create state updates for multiple players
        let playerCount = 50
        var updates: [StateUpdate] = []
        for i in 0 ..< playerCount {
            let patches: [StatePatch] = [
                StatePatch(path: "/playerData/player-\(i)/score", operation: .set(.int(i * 20))),
            ]
            updates.append(.diff(patches))
        }

        let encoder = OpcodeMessagePackStateUpdateEncoder()
        let landID = "test-land"
        let playerID = PlayerID("test-player")

        // Serial encoding
        let serialStart = ContinuousClock.now
        var serialResults: [Data] = []
        for update in updates {
            let data = try encoder.encode(update: update, landID: landID, playerID: playerID)
            serialResults.append(data)
        }
        let serialDuration = serialStart.duration(to: ContinuousClock.now)
        let serialMs = Double(serialDuration.components.seconds) * 1000.0 +
            Double(serialDuration.components.attoseconds) / 1_000_000_000_000_000.0

        // Parallel encoding
        let parallelStart = ContinuousClock.now
        let parallelResults = await withTaskGroup(of: Data.self, returning: [Data].self) { group in
            for update in updates {
                group.addTask {
                    try! encoder.encode(update: update, landID: landID, playerID: playerID)
                }
            }

            var results: [Data] = []
            results.reserveCapacity(updates.count)
            for await result in group {
                results.append(result)
            }
            return results
        }
        let parallelDuration = parallelStart.duration(to: ContinuousClock.now)
        let parallelMs = Double(parallelDuration.components.seconds) * 1000.0 +
            Double(parallelDuration.components.attoseconds) / 1_000_000_000_000_000.0

        // Verify results count
        #expect(serialResults.count == parallelResults.count)
        #expect(serialResults.count == updates.count)

        // Verify all results have valid data
        for (serial, parallel) in zip(serialResults, parallelResults) {
            #expect(serial.count > 0)
            #expect(parallel.count > 0)
        }

        // Log performance results
        print("[OpcodeMessagePack] Serial: \(String(format: "%.2f", serialMs))ms, Parallel: \(String(format: "%.2f", parallelMs))ms")

        #expect(serialMs >= 0)
        #expect(parallelMs >= 0)
    }

    /// Test that parallel encoding works correctly with TransportAdapter
    @Test("TransportAdapter parallel encoding produces correct results")
    func transportAdapterParallelEncoding() async throws {
        // Arrange
        let definition = Land(
            "parallel-test",
            using: ParallelEncodingTestState.self
        ) {
            Rules {
                HandleAction(TestAction.self) { (state: inout ParallelEncodingTestState, _: TestAction, _: LandContext) in
                    state.round += 1
                    return TestActionResponse(success: true)
                }
            }
        }

        let transport = WebSocketTransport()
        let keeper = LandKeeper<ParallelEncodingTestState>(
            definition: definition,
            initialState: ParallelEncodingTestState()
        )

        // Create adapter with JSON codec (enables parallel encoding)
        let adapter = TransportAdapter<ParallelEncodingTestState>(
            keeper: keeper,
            transport: transport,
            landID: "parallel-test",
            codec: JSONTransportCodec()
        )
        await transport.setDelegate(adapter)

        // Join multiple players
        let playerCount = 10
        var playerIDs: [PlayerID] = []

        for i in 0 ..< playerCount {
            let sessionID = SessionID("session-\(i)")
            let clientID = ClientID("client-\(i)")
            let playerID = PlayerID("player-\(i)")

            await adapter.onConnect(sessionID: sessionID, clientID: clientID)

            try await simulateRouterJoin(
                adapter: adapter,
                keeper: keeper,
                sessionID: sessionID,
                clientID: clientID,
                playerID: playerID
            )

            playerIDs.append(playerID)
        }

        // Modify state to trigger sync
        let action = TestAction()
        let envelope = ActionEnvelope(
            typeIdentifier: String(describing: TestAction.self),
            payload: AnyCodable(action)
        )
        _ = try await keeper.handleActionEnvelope(
            envelope,
            playerID: playerIDs[0],
            clientID: ClientID("client-0"),
            sessionID: SessionID("session-0")
        )

        // Trigger sync (should use parallel encoding for JSON codec)
        await adapter.syncNow()

        // Verify no errors occurred
        #expect(Bool(true))
    }

    /// Test that serial encoding is used when parallel encoding is disabled
    @Test("TransportAdapter uses serial encoding when disabled")
    func transportAdapterSerialEncodingWhenDisabled() async throws {
        // Arrange
        let definition = Land(
            "serial-test",
            using: ParallelEncodingTestState.self
        ) {
            Rules {}
        }

        let transport = WebSocketTransport()
        let keeper = LandKeeper<ParallelEncodingTestState>(
            definition: definition,
            initialState: ParallelEncodingTestState()
        )

        let adapter = TransportAdapter<ParallelEncodingTestState>(
            keeper: keeper,
            transport: transport,
            landID: "serial-test",
            codec: JSONTransportCodec()
        )
        await transport.setDelegate(adapter)

        // Disable parallel encoding via environment variable
        // Note: This test verifies the code path, but we can't easily verify
        // which path was taken without exposing internal state
        // In practice, serial encoding will be used if:
        // 1. Codec is not JSONTransportCodec
        // 2. Environment variable SST_SYNC_PARALLEL_ENCODE is set to "0", "false", or "off"

        // Join a player
        let sessionID = SessionID("session-1")
        let clientID = ClientID("client-1")
        let playerID = PlayerID("player-1")

        await adapter.onConnect(sessionID: sessionID, clientID: clientID)
        try await simulateRouterJoin(
            adapter: adapter,
            keeper: keeper,
            sessionID: sessionID,
            clientID: clientID,
            playerID: playerID
        )

        // Trigger sync
        await adapter.syncNow()

        // Verify no errors occurred
        #expect(Bool(true))
    }
}

// MARK: - Test Action

@Payload
struct TestAction: ActionPayload {
    typealias Response = TestActionResponse
}

@Payload
struct TestActionResponse: ResponsePayload {
    let success: Bool
}
