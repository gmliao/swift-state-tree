// Tests/SwiftStateTreeTests/ReplayPayloadDecodeFailureTests.swift
//
// Pins how replay reports a recorded payload that doesn't decode, before #700 K1a moves replay's
// decode from apply to item building (plan §3.11, "Replay's decode failures"). K1a keeps these
// tests green unchanged:
// - an action whose payload doesn't decode is refused before its record: not applied, not in the
//   replayed `rejected` list (so no divergence against a frame that lists none), and logged with
//   the decode error's description;
// - a client event whose payload doesn't decode is dropped by its handler and not counted;
// - a client event nested past the limit is dropped and counted once.
// Actions and client events are interleaved by sequence, so a replay that applied one kind before
// the other would change the order of `hits`.

import Foundation
import Logging
import Testing
@testable import SwiftStateTree

@Suite("Replay reports a recorded payload that doesn't decode (#700 K1a pins it)")
struct ReplayPayloadDecodeFailureTests {
    /// A recorded input, numbered by its position in the record's list.
    enum Input {
        case action(String)
        case event(String)
    }

    /// A record of this build's version with one tick frame; each input's payload is its JSON
    /// text's bytes (#700 K1a). Each input's sequence is its index in `inputs`, so the frame's
    /// actions and client events interleave. `rejected` is the frame's list of
    /// refused inputs; nil leaves it out.
    static func record(_ inputs: [Input], rejected: [Int64]? = nil) -> Data {
        var actions: [String] = []
        var events: [String] = []
        for (sequence, input) in inputs.enumerated() {
            switch input {
            case .action(let payload):
                actions.append(#"{"kind":"action","sequence":\#(sequence),"typeIdentifier":"\#(String(describing: ReplayDecodeAction.self))","payload":"\#(Data(payload.utf8).base64EncodedString())","playerID":"p","clientID":"c","sessionID":"s","resolverOutputs":{},"resolvedAtTick":0}"#)
            case .event(let payload):
                events.append(#"{"kind":"clientEvent","sequence":\#(sequence),"typeIdentifier":"\#(payloadEventName(for: ReplayDecodeEvent.self))","payload":"\#(Data(payload.utf8).base64EncodedString())","playerID":"p","clientID":"c","sessionID":"s","resolvedAtTick":0}"#)
            }
        }
        let rejectedField = rejected.map { #","rejected":[\#($0.map(String.init).joined(separator: ","))]"# } ?? ""
        let text = #"{"recordMetadata":{"landID":"l","landType":"replay-decode","createdAt":"1970-01-01T00:00:00Z","metadata":{},"version":"\#(ReevaluationRecordVersion.current)"},"tickFrames":[{"tickId":0,"actions":["#
            + actions.joined(separator: ",") + #"],"clientEvents":["# + events.joined(separator: ",")
            + #"],"lifecycleEvents":[]"# + rejectedField + "}]}"
        return Data(text.utf8)
    }

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
                HandleAction(ReplayDecodeAction.self) { state, action, _ in
                    state.hits.append("action:\(action.tag)")
                    return ReplayDecodeResponse(count: state.hits.count)
                }
                HandleEvent(ReplayDecodeEvent.self) { state, event, _ in
                    state.hits.append("event:\(event.tag)")
                }
            }
            Lifetime {
                Tick(every: .seconds(3600)) { _, _ in }
            }
        }
    }

    /// What one replayed tick left behind.
    struct Replayed {
        let hits: [String]
        let mismatch: String?
        let refusals: [(level: Logger.Level, message: String, metadata: Logger.Metadata)]
        let dropped: Int
    }

    /// Replays tick 0 of `data`, comparing refused inputs with the frame's list, and counts the
    /// drops noted in this replay only.
    static func replay(_ data: Data) async throws -> Replayed {
        let logs = ResolverReplayLogRecords()
        let keeper = LandKeeper<ReplayDecodeState>(
            definition: definition(),
            initialState: ReplayDecodeState(),
            mode: .reevaluation,
            reevaluationSource: try JSONReevaluationSource(data: data),
            autoStartLoops: false,
            logger: Logger(label: "replay-decode-failure") { _ in ResolverReplayLogHandler(records: logs) }
        )
        // As for a record from 3.5 on, which lists every refused input.
        await keeper.setReplayRecordsRejected(true)
        let dropped = PayloadNesting.WalkCounter()
        await PayloadNesting.$droppedForTesting.withValue(dropped) {
            await keeper.stepTickOnce()
        }
        return Replayed(
            hits: await keeper.currentState().hits,
            mismatch: await keeper.takeRecordedPassMismatch(for: 0),
            refusals: logs.all.filter { $0.level == .error && $0.message.hasPrefix("Input refused") },
            dropped: dropped.count
        )
    }

    /// The text replay logs for the bad action: the description of the error its decode throws.
    static func badActionError() throws -> String {
        do {
            _ = try JSONDecoder().decode(ReplayDecodeAction.self, from: Data(#"{"tag":5}"#.utf8))
        } catch {
            return String(describing: error)
        }
        Issue.record("the bad payload decoded")
        return ""
    }

    /// Good and bad inputs interleaved: the bad action is sequence 3.
    static let inputs: [Input] = [
        .event(#"{"tag":"e1"}"#),
        .action(#"{"tag":"a"}"#),
        .event(#"{"tag":5}"#),
        .action(#"{"tag":5}"#),
        .event(#"{"tag":"e2"}"#),
    ]

    @Test("A bad action is refused before its record and logged; an event that doesn't decode is dropped and not counted")
    func replayPayloadDecodeFailureIsReportedAsBefore() async throws {
        let replayed = try await Self.replay(Self.record(Self.inputs))

        // Only the good inputs applied, in sequence order across both kinds.
        #expect(replayed.hits == ["event:e1", "action:a", "event:e2"])
        // The bad action isn't listed as refused: it threw before its record. The frame lists
        // none, so a replay that listed it would report a divergence for tick 0.
        #expect(replayed.mismatch == nil)
        // The event with a number for `tag` is dropped without being counted.
        #expect(replayed.dropped == 0)
        // The refusal's log line names the bad action (sequence 3) and the decode error's text.
        #expect(replayed.refusals.count == 1)
        #expect(replayed.refusals.first?.metadata["sequence"] == .stringConvertible(3))
        #expect(replayed.refusals.first?.metadata["error"] == .string(try Self.badActionError()))
    }

    @Test("A client event nested past the limit is dropped and counted once")
    func tooDeepEventIsDroppedAndCounted() async throws {
        let replayed = try await Self.replay(Self.record([
            .action(#"{"tag":"a"}"#),
            .event(Self.tooDeepEventPayload()),
            .event(#"{"tag":"e"}"#),
        ]))
        #expect(replayed.hits == ["action:a", "event:e"])
        #expect(replayed.mismatch == nil)
        #expect(replayed.refusals.isEmpty)
        #expect(replayed.dropped == 1)
    }

    @Test("Control: a frame that lists the bad action as refused reports a divergence for tick 0")
    func frameListingTheBadActionDiverges() async throws {
        let replayed = try await Self.replay(Self.record(Self.inputs, rejected: [3]))
        // The comparison runs on this land: the `mismatch == nil` above can fail.
        #expect(replayed.mismatch != nil)
        #expect(replayed.hits == ["event:e1", "action:a", "event:e2"])
    }
}
