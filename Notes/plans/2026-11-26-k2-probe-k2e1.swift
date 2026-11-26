// P-K2E-1 (K2 plan §4.4, K1b-5 plan D15.3 rev 2.10): the numbering and the sync requests of
// every handler that passes outputs, on main before the move. Not for commit: its output is the
// golden the move's tests compare with. It ran as a test file on main at fb1457e6 (macOS, debug)
// and printed:
//
//   after join p1: syncRequestTicks=[-1] eventTicks=[-1]
//   refused join: roomIsFull
//   after refused join: syncRequestTicks=[-1] eventTicks=[-1, -1]
//   after action: syncRequestTicks=[-1] eventTicks=[-1, -1]
//   after tick 0: syncRequestTicks=[-1] eventTicks=[-1, -1]
//   after sync: syncRequestTicks=[-1, 0] eventTicks=[-1, -1, 0]
//   after tick 1: syncRequestTicks=[-1, 0] eventTicks=[-1, -1, 0, 0]
//   frame 0: before=Optional(4) handler=Optional(6) lifecycle=["join@1"] actions=["action@3"] events=["4:{\"from\":\"onJoin\"}", "5:{\"from\":\"action\"}", "6:{\"from\":\"tick\"}"]
//   frame 1: before=Optional(10) handler=Optional(11) lifecycle=["join@9"] actions=[] events=["10:{\"from\":\"onJoin\"}", "11:{\"from\":\"tick\"}"]


import Foundation
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct ProbeK2E1State: StateNodeProtocol {
    @Sync(.broadcast)
    var ticks: Int = 0

    public init() {}
}

@Payload
struct ProbeK2E1Action: ActionPayload {
    typealias Response = ProbeK2E1Ack
    let amount: Int
}

@Payload
struct ProbeK2E1Ack: ResponsePayload {
    let ok: Bool
}

@Payload
struct ProbeK2E1Event: ServerEventPayload {
    let from: String
}

private func probeK2E1Land() -> LandDefinition<ProbeK2E1State> {
    Land("probe-k2e1", using: ProbeK2E1State.self) {
        ServerEvents { Register(ProbeK2E1Event.self) }
        Rules {
            CanJoin { _, session, ctx in
                ctx.emitEvent(ProbeK2E1Event(from: "canJoin"), to: .all)
                ctx.requestSyncNow()
                if session.playerID == "refused" { throw JoinError.roomIsFull }
                return .allow(playerID: PlayerID(session.playerID))
            }
            OnJoin { _, ctx in
                ctx.emitEvent(ProbeK2E1Event(from: "onJoin"), to: .all)
                ctx.requestSyncBroadcastOnly()
            }
            HandleAction(ProbeK2E1Action.self) { _, _, ctx in
                ctx.emitEvent(ProbeK2E1Event(from: "action"), to: .all)
                ctx.requestSyncNow()
                return ProbeK2E1Ack(ok: true)
            }
        }
        Lifetime {
            Tick(every: .seconds(3600)) { state, ctx in
                state.ticks += 1
                ctx.emitEvent(ProbeK2E1Event(from: "tick"), to: .all)
                ctx.requestSyncBroadcastOnly()
            }
            StateSync(every: .seconds(3600)) { _, ctx in
                ctx.emitEvent(ProbeK2E1Event(from: "syncHandler"), to: .all)
                ctx.requestSyncNow()
            }
        }
    }
}

private func probeK2E1Envelope() -> ActionEnvelope {
    ActionEnvelope(
        typeIdentifier: String(describing: ProbeK2E1Action.self),
        payload: AnyCodable(ProbeK2E1Action(amount: 1))
    )
}

@Suite("PROBE K2E-1", .timeLimit(.minutes(1)))
struct ProbeK2E1Tests {
    @Test("PROBE K2E-1: numbering and sync requests of every passing scope")
    func probe() async throws {
        let landID = "probe-k2e1:\(UUID().uuidString)"
        let definition = probeK2E1Land()
        let keeper = LandKeeper<ProbeK2E1State>(
            definition: definition,
            initialState: ProbeK2E1State(),
            enableLiveStateHashRecording: true,
            landID: landID
        )
        let recorder = try #require(await keeper.getReevaluationRecorder())
        await recorder.setMetadata(ReevaluationRecordMetadata(
            landID: landID, landType: definition.id,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), metadata: [:],
            landDefinitionID: definition.id, rngSeed: DeterministicSeed.fromLandID(landID),
            version: ReevaluationRecordVersion.current
        ))
        func log(_ step: String) async {
            print("probe-k2e1 \(step): syncRequestTicks=\(await keeper.syncRequestTicksForTesting()) eventTicks=\(await keeper.emittedEventTicksForTesting())")
        }
        _ = try await keeper.join(session: PlayerSession(playerID: "p1"), clientID: ClientID("c1"), sessionID: SessionID("s1"), services: LandServices())
        await log("after join p1")
        do {
            _ = try await keeper.join(session: PlayerSession(playerID: "refused"), clientID: ClientID("c9"), sessionID: SessionID("s9"), services: LandServices())
        } catch {
            print("probe-k2e1 refused join: \(error)")
        }
        await log("after refused join")
        _ = try await keeper.handleActionEnvelope(probeK2E1Envelope(), playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1"))
        await log("after action")
        await keeper.stepTickOnce()
        await log("after tick 0")
        await keeper.runSyncLoopIterationForTesting()
        await log("after sync")
        _ = try await keeper.join(session: PlayerSession(playerID: "p2"), clientID: ClientID("c2"), sessionID: SessionID("s2"), services: LandServices())
        await keeper.stepTickOnce()
        await log("after tick 1")
        await keeper.waitForRecorderSubmissionsForTesting()
        for frame in await recorder.getAllFrames() {
            let events = frame.serverEvents.map { "\($0.sequence):\(String(decoding: (try? JSONEncoder().encode($0.payload)) ?? Data(), as: UTF8.self))" }
            let lifecycle = frame.lifecycleEvents.map { "\($0.kind)@\($0.sequence)" }
            let actions = frame.actions.map { "action@\($0.sequence)" }
            print("probe-k2e1 frame \(frame.tickId): before=\(String(describing: frame.sequenceBeforeInputs)) handler=\(String(describing: frame.sequenceBeforeTickHandler)) lifecycle=\(lifecycle) actions=\(actions) events=\(events)")
        }
        await keeper.forceShutdown()
    }
}
