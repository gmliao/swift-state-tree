// Tests/SwiftStateTreeTransportTests/SyncStreamInitializeRecordTests.swift
//
// Record format 2.1, live side: the initialize record (both sync paths), the initialize marker
// (in-turn sync only) and the header's `recordsSyncStream`.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

@StateNodeBuilder
struct InitRecordTestState: StateNodeProtocol {
    @Sync(.broadcast) var value: Int = 0
    @Sync(.broadcast) var ticks: Int = 0
    init() {}
}

@Payload
struct InitRecordEvent: ServerEventPayload {
    let message: String
    init(message: String) {
        self.message = message
    }
}

struct InitRecordResolverOutput: ResolverOutput {
    let value: Int
}

/// Gates per land ID, so each test holds its own OnInitialize resolver.
private final class InitResolverGates: @unchecked Sendable {
    private let lock = NSLock()
    private var gates: [String: TestGate] = [:]

    func withLock<T>(_ body: (inout [String: TestGate]) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&gates)
    }
}

private let initResolverGates = InitResolverGates()

/// Waits at the land's gate (if any), then resolves 7.
struct GatedInitResolver: ContextResolver {
    typealias Output = InitRecordResolverOutput

    static func resolve(ctx: ResolverContext) async throws -> InitRecordResolverOutput {
        let gate = initResolverGates.withLock { $0[ctx.landID] }
        await gate?.arrive()
        return InitRecordResolverOutput(value: 7)
    }
}

private func makeInitRecordLand() -> LandDefinition<InitRecordTestState> {
    Land("init-record-test", using: InitRecordTestState.self) {
        ServerEvents { Register(InitRecordEvent.self) }
        Lifetime {
            OnInitialize(resolvers: GatedInitResolver.self) { (state: inout InitRecordTestState, ctx: LandContext) in
                let resolved: InitRecordResolverOutput? = ctx.gatedInit
                state.value = resolved?.value ?? -1
                ctx.emitEvent(InitRecordEvent(message: "initialized"), to: .all)
            }
            Tick(every: .seconds(3600)) { (state: inout InitRecordTestState, _: LandContext) in
                state.ticks += 1
            }
        }
    }
}

private actor InitRecordTransport: Transport {
    var delegate: TransportDelegate?
    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {}
    func sendBatch(_ updates: [(Data, SwiftStateTreeTransport.EventTarget)]) async {}
}

private struct InitRecordFixture {
    let keeper: LandKeeper<InitRecordTestState>
    let adapter: TransportAdapter<InitRecordTestState>

    /// A recording keeper whose OnInitialize resolver waits at a gate. With
    /// `transportBeforeInitialize`, the adapter is attached while the resolver waits, so
    /// OnInitialize runs as a turn when in-turn sync is on; otherwise OnInitialize finishes
    /// before the adapter exists (the timing `LandManager` gives a land without resolvers).
    static func make(landID: String, inTurn: Bool, transportBeforeInitialize: Bool) async throws -> InitRecordFixture {
        let gate = TestGate()
        initResolverGates.withLock { $0[landID] = gate }
        let keeper = LandKeeper<InitRecordTestState>(
            definition: makeInitRecordLand(),
            initialState: InitRecordTestState(),
            enableLiveStateHashRecording: true,
            autoStartLoops: false,
            landID: landID
        )
        if !transportBeforeInitialize {
            gate.open()
            await keeper.stepTickOnce()
        } else {
            #expect(await gate.waitForArrivals(1), "the resolver is waiting")
        }
        let adapter = TransportAdapter<InitRecordTestState>(
            keeper: keeper,
            transport: InitRecordTransport(),
            landID: landID,
            inTurnSync: inTurn
        )
        await keeper.setTransport(adapter)
        gate.open()
        await keeper.stepTickOnce()
        initResolverGates.withLock { $0[landID] = nil }
        return InitRecordFixture(keeper: keeper, adapter: adapter)
    }

    func frame0() async throws -> ReevaluationTickFrame {
        let recorder = try #require(await keeper.getReevaluationRecorder())
        return try #require(await recorder.getAllFrames().first { $0.tickId == 0 })
    }
}

@Suite("Initialize record and marker (record format 2.1)", .timeLimit(.minutes(1)))
struct SyncStreamInitializeRecordTests {
    @Test("Both sync paths record OnInitialize's events and post-initialize state hash", arguments: [true, false])
    func initializeRecordOnBothPaths(inTurn: Bool) async throws {
        let f = try await InitRecordFixture.make(landID: "init-record-\(inTurn)", inTurn: inTurn, transportBeforeInitialize: true)
        #expect(await f.keeper.currentState().value == 7)
        let frame = try await f.frame0()
        let record = try #require(frame.initialize)
        #expect(record.serverEvents.map(\.typeIdentifier) == ["InitRecord"])
        #expect(record.serverEvents.allSatisfy { $0.sequence > record.sequence })
        var afterInitialize = InitRecordTestState()
        afterInitialize.value = 7
        #expect(record.stateHash == ReevaluationEngine.calculateStateHash(afterInitialize))
        #expect(frame.lifecycleEvents.map(\.kind) == ["initialize"])
    }

    @Test("With in-turn sync on, OnInitialize as a turn records an initialize marker at stream position 0")
    func markerInTurn() async throws {
        guard InTurnSync.isEnabled() else { return }
        let f = try await InitRecordFixture.make(landID: "init-marker-on", inTurn: true, transportBeforeInitialize: true)
        let frame = try await f.frame0()
        let record = try #require(frame.initialize)
        #expect(frame.syncMarkers == [
            ReevaluationRecordedSyncMarker(kind: .initialize, streamIndex: 0, sequence: record.sequence),
        ])
        #expect(await f.keeper.syncStreamCounterForTesting() == 1)
    }

    @Test("With in-turn sync off, nothing is numbered and no marker is recorded")
    func noMarkerOff() async throws {
        let f = try await InitRecordFixture.make(landID: "init-marker-off", inTurn: false, transportBeforeInitialize: true)
        let frame = try await f.frame0()
        #expect(frame.initialize != nil)
        #expect(frame.syncMarkers.isEmpty)
        #expect(frame.syncOutputs.isEmpty)
        #expect(await f.keeper.syncStreamCounterForTesting() == 0)
    }

    @Test("OnInitialize before the adapter exists records no marker: it precedes every sync output")
    func initializeBeforeTransport() async throws {
        let f = try await InitRecordFixture.make(landID: "init-before-transport", inTurn: true, transportBeforeInitialize: false)
        let frame = try await f.frame0()
        #expect(frame.initialize != nil)
        #expect(frame.syncMarkers.isEmpty)
        #expect(await f.keeper.syncStreamCounterForTesting() == 0)
    }
}

@Suite("Record header: recordsSyncStream")
struct SyncStreamRecordHeaderTests {
    @Test("LandManager writes version 2.1 and recordsSyncStream from the adapter's in-turn switch", arguments: [true, false])
    func header(inTurn: Bool) async throws {
        let manager = LandManager<InitRecordTestState>(
            landFactory: { _ in makeInitRecordLand() },
            initialStateFactory: { _ in InitRecordTestState() },
            enableLiveStateHashRecording: true,
            inTurnSync: inTurn
        )
        let landID = LandID(landType: "init-record-test", instanceId: "header-\(inTurn)")
        let container = try await manager.getOrCreateLand(landID: landID, definition: makeInitRecordLand(), initialState: InitRecordTestState(), metadata: [:])
        let recorder = try #require(await container.keeper.getReevaluationRecorder())
        let metadata = try #require(await recorder.getMetadata())
        #expect(metadata.version == "2.1")
        #expect(metadata.recordsSyncStream == (inTurn && InTurnSync.isEnabled()))
        #expect(metadata.recordsSyncStream == container.transportAdapter.inTurnSyncEnabled)
    }
}
