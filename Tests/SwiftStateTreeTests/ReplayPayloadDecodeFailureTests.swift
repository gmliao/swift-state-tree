// Tests/SwiftStateTreeTests/ReplayPayloadDecodeFailureTests.swift
//
// Pins how replay reports a recorded payload that doesn't decode, before #700 K1a moves replay's
// decode from apply to item building (plan §3.11, "Replay's decode failures"). K1a keeps this
// test green unchanged:
// - an action whose payload doesn't decode is refused before its record: not applied, not in the
//   replayed `rejected` list (so no divergence against a frame that lists none), and logged with
//   the decode error's description;
// - a client event whose payload doesn't decode is dropped by its handler and not counted;
// - a client event nested past the limit is dropped and counted once.

import Foundation
import Logging
import Testing
@testable import SwiftStateTree

@Suite("Replay reports a recorded payload that doesn't decode (#700 K1a pins it)")
struct ReplayPayloadDecodeFailureTests {
    /// A client event payload nested one level deeper than the limit, under a field the event
    /// type doesn't read.
    static func tooDeepEventPayload() -> String {
        let depth = PayloadNesting.clientFrameMaxDepth + 1
        return #"{"tag":"deep","n":"# + String(repeating: "[", count: depth)
            + String(repeating: "]", count: depth) + "}"
    }

    /// `ReplayInputDecodeTests`' land with a tick: replay compares a tick land's refused inputs
    /// with its frame's `rejected` list, and a tickless frame without passes has none to compare.
    static func definition() -> LandDefinition<ReplayDecodeState> {
        Land("replay-decode", using: ReplayDecodeState.self) {
            ClientEvents { Register(ReplayDecodeEvent.self) }
            Rules {
                HandleAction(ReplayDecodeAction.self) { (state: inout ReplayDecodeState, action: ReplayDecodeAction, _: LandContext) in
                    state.hits.append("action:\(action.tag)")
                    return ReplayDecodeResponse(count: state.hits.count)
                }
                HandleEvent(ReplayDecodeEvent.self) { (state: inout ReplayDecodeState, event: ReplayDecodeEvent, _: LandContext) in
                    state.hits.append("event:\(event.tag)")
                }
            }
            Lifetime {
                Tick(every: .seconds(3600)) { (_: inout ReplayDecodeState, _: LandContext) in }
            }
        }
    }

    @Test("A bad action is refused before its record and logged; a bad event is dropped; a too-deep event is dropped and counted")
    func replayPayloadDecodeFailureIsReportedAsBefore() async throws {
        let data = ReplayInputDecodeTests.record(
            actions: [#"{"tag":"a"}"#, #"{"tag":5}"#],
            events: [#"{"tag":5}"#, Self.tooDeepEventPayload(), #"{"tag":"e"}"#]
        )
        let logs = ResolverReplayLogRecords()
        let keeper = LandKeeper<ReplayDecodeState>(
            definition: Self.definition(),
            initialState: ReplayDecodeState(),
            mode: .reevaluation,
            reevaluationSource: try JSONReevaluationSource(data: data),
            autoStartLoops: false,
            logger: Logger(label: "replay-decode-failure") { _ in ResolverReplayLogHandler(records: logs) }
        )
        // The frame lists no refused input (a record from 3.5 on lists every one), so a replay
        // that listed the bad action as refused would report a divergence for tick 0.
        await keeper.setReplayRecordsRejected(true)

        let dropped = PayloadNesting.WalkCounter()
        await PayloadNesting.$droppedForTesting.withValue(dropped) {
            await keeper.stepTickOnce()
        }

        // Only the good inputs applied, in record order: the bad action and both bad events didn't.
        #expect(await keeper.currentState().hits == ["action:a", "event:e"])
        // The bad action isn't listed as refused: it threw before its record.
        #expect(await keeper.takeRecordedPassMismatch(for: 0) == nil)
        // One drop counted: the too-deep event. The event with a number for `tag` isn't counted.
        #expect(dropped.count == 1)

        // The refusal's log line names the bad action (sequence 1) and the decode error's text.
        let expected: String
        do {
            _ = try JSONDecoder().decode(ReplayDecodeAction.self, from: Data(#"{"tag":5}"#.utf8))
            Issue.record("the bad payload decoded")
            return
        } catch {
            expected = String(describing: error)
        }
        let refusals = logs.all.filter { $0.level == .error && $0.message.hasPrefix("Input refused") }
        #expect(refusals.count == 1)
        #expect(refusals.first?.metadata["sequence"] == .stringConvertible(1))
        #expect(refusals.first?.metadata["error"] == .string(expected))
    }
}
