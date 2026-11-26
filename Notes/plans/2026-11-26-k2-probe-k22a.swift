// P-K2-2a (K2 plan §4.4, §4.5): P-K2E-1's land without a tick handler. On a tickless land, is a
// handler's event taken by a later segment than the one that emitted it (CanJoin's, the sync
// handler's)? If so, a K2 step can't keep the emitted-events list step-local. It ran as a test file
// on main at 2f2d2439 (macOS, debug) and printed:
//
//   after join p1: syncRequestTicks=[-1] eventTicks=[-1]
//   refused join: roomIsFull
//   after refused join: syncRequestTicks=[-1] eventTicks=[-1, -1]
//   after action: syncRequestTicks=[-1] eventTicks=[-1, -1]
//   after sync: syncRequestTicks=[-1] eventTicks=[-1, -1, -1]
//   after join p2: syncRequestTicks=[-1] eventTicks=[-1, -1, -1, -1]
//   after action 2: syncRequestTicks=[-1] eventTicks=[-1, -1, -1, -1]
//   frame 0: before=nil handler=nil lifecycle=["join@1", "join@8"] actions=["action@4", "action@10"] events=["2:{\"from\":\"onJoin\"}", "5:{\"from\":\"action\"}", "9:{\"from\":\"onJoin\"}", "11:{\"from\":\"action\"}"]


import Foundation
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct ProbeK22AState: StateNodeProtocol {
    @Sync(.broadcast)
    var ticks: Int = 0

    public init() {}
}

@Payload
struct ProbeK22AAction: ActionPayload {
    typealias Response = ProbeK22AAck
    let amount: Int
}

@Payload
struct ProbeK22AAck: ResponsePayload {
    let ok: Bool
}

@Payload
struct ProbeK22AEvent: ServerEventPayload {
    let from: String
}

private func probeK22ALand() -> LandDefinition<ProbeK22AState> {
    Land("probe-k22a", using: ProbeK22AState.self) {
        ServerEvents { Register(ProbeK22AEvent.self) }
        Rules {
            CanJoin { _, session, ctx in
                ctx.emitEvent(ProbeK22AEvent(from: "canJoin"), to: .all)
                ctx.requestSyncNow()
                if session.playerID == "refused" { throw JoinError.roomIsFull }
                return .allow(playerID: PlayerID(session.playerID))
            }
            OnJoin { _, ctx in
                ctx.emitEvent(ProbeK22AEvent(from: "onJoin"), to: .all)
                ctx.requestSyncBroadcastOnly()
            }
            HandleAction(ProbeK22AAction.self) { _, _, ctx in
                ctx.emitEvent(ProbeK22AEvent(from: "action"), to: .all)
                ctx.requestSyncNow()
                return ProbeK22AAck(ok: true)
            }
        }
        Lifetime {
            StateSync(every: .seconds(3600)) { _, ctx in
                ctx.emitEvent(ProbeK22AEvent(from: "syncHandler"), to: .all)
                ctx.requestSyncNow()
            }
        }
    }
}

private func probeK22AEnvelope() -> ActionEnvelope {
    ActionEnvelope(
        typeIdentifier: String(describing: ProbeK22AAction.self),
        payload: AnyCodable(ProbeK22AAction(amount: 1))
    )
}

@Suite("PROBE K2-2a", .timeLimit(.minutes(1)))
struct ProbeK22ATests {
    @Test("PROBE K2-2a: numbering and sync requests of every passing scope")
    func probe() async throws {
        let landID = "probe-k22a:\(UUID().uuidString)"
        let definition = probeK22ALand()
        let keeper = LandKeeper<ProbeK22AState>(
            definition: definition,
            initialState: ProbeK22AState(),
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
            print("probe-k22a \(step): syncRequestTicks=\(await keeper.syncRequestTicksForTesting()) eventTicks=\(await keeper.emittedEventTicksForTesting())")
        }
        _ = try await keeper.join(session: PlayerSession(playerID: "p1"), clientID: ClientID("c1"), sessionID: SessionID("s1"), services: LandServices())
        await log("after join p1")
        do {
            _ = try await keeper.join(session: PlayerSession(playerID: "refused"), clientID: ClientID("c9"), sessionID: SessionID("s9"), services: LandServices())
        } catch {
            print("probe-k22a refused join: \(error)")
        }
        await log("after refused join")
        _ = try await keeper.handleActionEnvelope(probeK22AEnvelope(), playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1"))
        await log("after action")
        await keeper.runSyncLoopIterationForTesting()
        await log("after sync")
        _ = try await keeper.join(session: PlayerSession(playerID: "p2"), clientID: ClientID("c2"), sessionID: SessionID("s2"), services: LandServices())
        await log("after join p2")
        _ = try await keeper.handleActionEnvelope(probeK22AEnvelope(), playerID: PlayerID("p2"), clientID: ClientID("c2"), sessionID: SessionID("s2"))
        await log("after action 2")
        await keeper.waitForRecorderSubmissionsForTesting()
        for frame in await recorder.getAllFrames() {
            let events = frame.serverEvents.map { "\($0.sequence):\(String(decoding: (try? JSONEncoder().encode($0.payload)) ?? Data(), as: UTF8.self))" }
            let lifecycle = frame.lifecycleEvents.map { "\($0.kind)@\($0.sequence)" }
            let actions = frame.actions.map { "action@\($0.sequence)" }
            print("probe-k22a frame \(frame.tickId): before=\(String(describing: frame.sequenceBeforeInputs)) handler=\(String(describing: frame.sequenceBeforeTickHandler)) lifecycle=\(lifecycle) actions=\(actions) events=\(events)")
        }
        await keeper.forceShutdown()
    }
}
