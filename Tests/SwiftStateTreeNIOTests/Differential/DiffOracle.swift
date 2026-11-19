// Tests/SwiftStateTreeNIOTests/Differential/DiffOracle.swift
//
// The property oracle (#555, plan §5.6): checks one run on its own, so a bug the golden and the
// branch share still fails.
// - Convergence, at the live checkpoint: each live joined client's state, from its frames
//   decoded and applied, equals the keeper's view for its player.
// - Request outcomes: each request the scenario sends gets what the scenario states (one
//   reply, one correlated error, or neither), and no frame answers a request it doesn't list.
// - Lifecycle: the record's join and leave entries, per player and in order, are the
//   scenario's.
// Every frame must classify: a server message, or a state update. One that is neither fails.

#if DEBUG
import Foundation
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

/// One frame, classified.
enum DiffClassifiedFrame {
    case message(TransportMessage)
    case state(DecodedStateUpdate)
    /// A MessagePack frame the state decoder passes over (an event, the merged frame's events).
    case other
}

/// Decodes one connection's frames in order, with that connection's own decoder state.
struct DiffFrameReader {
    let encoding: DiffEncoding
    private let codec: any TransportCodec
    private let opcode: OpcodeJSONStateUpdateDecoder
    private let json = JSONStateUpdateDecoder()

    init(encoding: DiffEncoding) {
        self.encoding = encoding
        self.codec = encoding.config.makeCodec()
        self.opcode = OpcodeJSONStateUpdateDecoder(
            pathHasher: nil, atomicLayout: AtomicLayoutTable.forState(DiffState.self), pathIndex: true, syncSequence: true
        )
    }

    func classify(_ data: Data) throws -> DiffClassifiedFrame {
        // The handshake replies are JSON in every encoding; the rest use the cell's codec.
        if let message = try? JSONDecoder().decode(TransportMessage.self, from: data) { return .message(message) }
        if let message = try? codec.decode(TransportMessage.self, from: data) { return .message(message) }
        if encoding == .opcode, let message = try? OpcodeTransportMessageDecoder().decode(from: data) { return .message(message) }
        switch encoding {
        case .json:
            return .state(try json.decode(data: data))
        case .opcode:
            guard let decoded = try opcode.decodeFrame(data, format: .json) else { return .other }
            return .state(decoded)
        case .messagepack:
            guard let decoded = try opcode.decodeFrame(data, format: .messagePack) else { return .other }
            return .state(decoded)
        }
    }
}

enum DiffOracle {
    /// The live checkpoint's convergence check: every live joined client holds its player's view.
    /// A scenario with no such client is refused, so the check can't compare nothing.
    static func convergence(_ run: DiffRun, _ capture: DiffCapture) async throws {
        let state = await run.keeper.currentState()
        var compared = 0
        for name in capture.connections.keys.sorted() {
            guard let connection = capture.connections[name], connection.close == nil,
                  !run.disconnected.contains(name) else { continue }
            let reader = DiffFrameReader(encoding: run.cell.encoding)
            var player: String?
            var view = SnapshotClientView()
            for (index, frame) in connection.frames.enumerated() {
                let classified: DiffClassifiedFrame
                do {
                    classified = try reader.classify(frame.bytes)
                } catch {
                    throw DiffRunFailure("\(name) frame \(index) is neither a message nor a state update: \(error); it is \(DiffValue.canonicalText(frame.decoded))")
                }
                switch classified {
                case .message(let message):
                    if case .joinResponse(let reply) = message.payload, reply.success { player = reply.playerID }
                case .state(let decoded):
                    if decoded.resync { view = SnapshotClientView() }
                    switch decoded.update {
                    case .noChange: break
                    case .diff(let patches), .firstSync(let patches):
                        do { try view.apply(patches) } catch {
                            throw DiffRunFailure("\(name) frame \(index) doesn't apply to its view: \(error)")
                        }
                    }
                case .other:
                    break
                }
            }
            guard let player else { continue }
            let expected = try state.snapshot(for: PlayerID(player), dirtyFields: nil).values
            guard normalized(view.fields) == normalized(expected) else {
                throw DiffRunFailure("\(name) (\(player)) didn't converge: it holds \(view.fields), the keeper's view is \(expected)")
            }
            compared += 1
        }
        guard compared > 0 else { throw DiffRunFailure("no live joined client at the live checkpoint") }
    }

    /// The outcomes of the scenario's requests, from the terminal capture.
    static func outcomes(_ scenario: DiffScenario, _ result: DiffRunResult, cell: DiffCell) throws {
        let expected = scenario.outcomes(in: cell)
        let encoding = cell.encoding
        var replies: [String: Int] = [:]
        var errors: [String: Int] = [:]
        for name in result.terminal.connections.keys.sorted() {
            let reader = DiffFrameReader(encoding: encoding)
            for (index, frame) in (result.terminal.connections[name]?.frames ?? []).enumerated() {
                let classified: DiffClassifiedFrame
                do { classified = try reader.classify(frame.bytes) } catch {
                    throw DiffRunFailure("\(name) frame \(index) is neither a message nor a state update: \(error)")
                }
                guard case .message(let message) = classified else { continue }
                switch message.payload {
                case .actionResponse(let reply):
                    replies[reply.requestID, default: 0] += 1
                case .joinResponse(let reply):
                    if reply.success { replies[reply.requestID, default: 0] += 1 } else { errors[reply.requestID, default: 0] += 1 }
                case .error(let error):
                    guard let id = error.details?["requestID"]?.base as? String else {
                        throw DiffRunFailure("\(name) frame \(index): an error frame with no request ID (\(error.code))")
                    }
                    errors[id, default: 0] += 1
                default:
                    break
                }
            }
        }
        for id in Set(replies.keys).union(errors.keys) where expected[id] == nil {
            throw DiffRunFailure("request \(id) was answered, and the scenario doesn't list it")
        }
        for (id, outcome) in expected.sorted(by: { $0.key < $1.key }) {
            let got = (replies[id] ?? 0, errors[id] ?? 0)
            let want: (Int, Int)
            switch outcome {
            case .reply: want = (1, 0)
            case .error: want = (0, 1)
            case .none: want = (0, 0)
            case .recorded(let issue):
                guard DiffOutcome.isIssueReference(issue) else {
                    throw DiffRunFailure("request \(id) is recorded without an issue reference (\"\(issue)\")")
                }
                guard got.0 + got.1 <= 1 else {
                    throw DiffRunFailure("request \(id): \(got.0) repl(ies) and \(got.1) error(s), more than one answer")
                }
                continue
            }
            guard got == want else {
                throw DiffRunFailure("request \(id): \(got.0) repl(ies) and \(got.1) error(s), the scenario states \(outcome)")
            }
        }
    }

    /// The record's join and leave entries per player, in record order.
    static func lifecycle(_ scenario: DiffScenario, _ result: DiffRunResult) throws {
        guard case .object(let root) = result.record.decoded, case .array(let frames)? = root["frames"] else {
            throw DiffRunFailure("the record has no frames")
        }
        var found: [String: [DiffLifecycle]] = [:]
        for frame in frames {
            guard case .object(let fields) = frame, case .array(let events)? = fields["lifecycleEvents"] else { continue }
            for event in events {
                guard case .object(let entry) = event, case .string(let kind)? = entry["kind"],
                      case .string(let player)? = entry["playerID"] else { continue }
                switch kind {
                case "join": found[player, default: []].append(.join)
                case "leave": found[player, default: []].append(.leave)
                default: continue
                }
            }
        }
        guard found == scenario.lifecycle else {
            throw DiffRunFailure("the record's lifecycle is \(found), the scenario states \(scenario.lifecycle)")
        }
    }

    /// Numbers as doubles: a JSON client reads every number as one.
    private static func normalized(_ fields: [String: SnapshotValue]) -> [String: SnapshotValue] {
        fields.mapValues(normalized)
    }

    private static func normalized(_ value: SnapshotValue) -> SnapshotValue {
        switch value {
        case .int(let v): return .double(Double(v))
        case .object(let fields): return .object(fields.mapValues(normalized))
        case .array(let items): return .array(items.map(normalized))
        default: return value
        }
    }
}
#endif
