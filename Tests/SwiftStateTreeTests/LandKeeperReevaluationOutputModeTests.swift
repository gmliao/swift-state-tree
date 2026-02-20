// Tests/SwiftStateTreeTests/LandKeeperReevaluationOutputModeTests.swift
//
// Tests for reevaluation output mode: sinkOnly vs transportAndSink

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Test State and Events

@StateNodeBuilder
struct OutputModeTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var ticks: Int = 0

    public init() {}
}

@Payload
struct OutputModeTestEvent: ServerEventPayload {
    let value: Int
}

func makeOutputModeTestDefinition() -> LandDefinition<OutputModeTestState> {
    Land("output-mode-test", using: OutputModeTestState.self) {
        ServerEvents {
            Register(OutputModeTestEvent.self)
        }
        Rules { }
        Lifetime {
            Tick(every: .seconds(3600)) { (state: inout OutputModeTestState, ctx: LandContext) in
                state.ticks += 1
                ctx.emitEvent(OutputModeTestEvent(value: state.ticks), to: .all)
            }
        }
    }
}

// MARK: - Mock Transport

private actor MockTransport: LandKeeperTransport {
    private(set) var sentEvents: [(AnyServerEvent, EventTarget)] = []

    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {
        sentEvents.append((event, target))
    }

    func syncNowFromTransport() async {}
    func syncBroadcastOnlyFromTransport() async {}
    func onLandDestroyed() async {}

    func eventCount() -> Int {
        sentEvents.count
    }
}

// MARK: - Mock Sink

private actor MockSink: ReevaluationSink {
    private(set) var eventsByTick: [Int64: [ReevaluationRecordedServerEvent]] = [:]

    func onEmittedServerEvents(tickId: Int64, events: [ReevaluationRecordedServerEvent]) async {
        guard !events.isEmpty else { return }
        var current = eventsByTick[tickId] ?? []
        current.append(contentsOf: events)
        eventsByTick[tickId] = current
    }

    func eventCount() -> Int {
        eventsByTick.values.flatMap { $0 }.count
    }
}

// MARK: - Tests

@Suite("LandKeeper Reevaluation Output Mode Tests")
struct LandKeeperReevaluationOutputModeTests {

    @Test("mode .reevaluation with outputMode .sinkOnly keeps current behavior - sink receives events, transport does not")
    func sinkOnlyKeepsCurrentBehavior() async throws {
        let definition = makeOutputModeTestDefinition()
        let metadata = ReevaluationRecordMetadata(
            landID: "output-mode-test:local",
            landType: "output-mode-test",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: [:],
            landDefinitionID: "output-mode-test",
            version: "1.0"
        )
        let frame = ReevaluationTickFrame(
            tickId: 0,
            actions: [],
            clientEvents: [],
            lifecycleEvents: []
        )
        let source = JSONReevaluationSource(metadata: metadata, frames: [frame])

        let mockSink = MockSink()
        let mockTransport = MockTransport()

        let keeper = LandKeeper<OutputModeTestState>(
            definition: definition,
            initialState: OutputModeTestState(),
            mode: .reevaluation,
            reevaluationSource: source,
            reevaluationSink: mockSink,
            reevaluationOutputMode: .sinkOnly,
            autoStartLoops: false,
            transport: mockTransport
        )
        await keeper.setLandID("output-mode-test:local")

        await keeper.stepTickOnce()

        let sinkCount = await mockSink.eventCount()
        let transportCount = await mockTransport.eventCount()

        #expect(sinkCount == 1, "Sink should receive 1 emitted event")
        #expect(transportCount == 0, "Transport should receive 0 events in sinkOnly mode")
    }

    @Test("mode .reevaluation with outputMode .transportAndSink forwards events to both transport and sink")
    func transportAndSinkForwardsToBoth() async throws {
        let definition = makeOutputModeTestDefinition()
        let metadata = ReevaluationRecordMetadata(
            landID: "output-mode-test:local",
            landType: "output-mode-test",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: [:],
            landDefinitionID: "output-mode-test",
            version: "1.0"
        )
        let frame = ReevaluationTickFrame(
            tickId: 0,
            actions: [],
            clientEvents: [],
            lifecycleEvents: []
        )
        let source = JSONReevaluationSource(metadata: metadata, frames: [frame])

        let mockSink = MockSink()
        let mockTransport = MockTransport()

        let keeper = LandKeeper<OutputModeTestState>(
            definition: definition,
            initialState: OutputModeTestState(),
            mode: .reevaluation,
            reevaluationSource: source,
            reevaluationSink: mockSink,
            reevaluationOutputMode: .transportAndSink,
            autoStartLoops: false,
            transport: mockTransport
        )
        await keeper.setLandID("output-mode-test:local")

        await keeper.stepTickOnce()

        let sinkCount = await mockSink.eventCount()
        let transportCount = await mockTransport.eventCount()

        #expect(sinkCount == 1, "Sink should receive 1 emitted event")
        #expect(transportCount == 1, "Transport should receive 1 event in transportAndSink mode")
    }
}
