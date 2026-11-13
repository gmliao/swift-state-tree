// Examples/GameDemo/Sources/EncodingBenchmark/InputInjection.swift
//
// Inputs from wire bytes (#521, PR 0). With `--inputs-from-wire`, the serial multi-room runners
// hand each input to the adapter as a client frame in the run's message encoding, so it goes
// through the transport's decode as a client's would: Hero Defense's moves (`--active-players`)
// and the visibility test's `SetMotionAction` (`--actions-per-player N`). Without the flag nothing
// here runs, and `--active-players` calls the keeper directly as before.

import Foundation
import GameContent
import SwiftStateTree
import SwiftStateTreeMessagePack
import SwiftStateTreeTransport

// MARK: - Settings

/// `--message-encoding`: the run's message encoding in place of the format's own. nil keeps the
/// format's: `json` for json-object and both opcode-json formats, `messagepack` for both
/// messagepack formats. Set once by `main` before any adapter exists.
enum MessageEncodingOverride {
    nonisolated(unsafe) static var current: TransportEncoding?

    /// The flag's values, as the help text names them.
    static let byName: [String: TransportEncoding] = [
        "json": .json,
        "opcode-json-array": .opcodeJsonArray,
        "messagepack": .messagepack,
    ]

    static func name(_ encoding: TransportEncoding) -> String {
        byName.first { $0.value == encoding }?.key ?? encoding.rawValue
    }
}

/// `--inputs-from-wire` and `--actions-per-player`, set once by `main` before any run.
enum InputRun {
    nonisolated(unsafe) static var fromWire = false
    /// Visibility test: `SetMotionAction`s per player per iteration (0: none).
    nonisolated(unsafe) static var actionsPerPlayer = 0

    /// Why the inputs can't run as given, or nil. Only the serial multi-room runners submit them,
    /// one room at a time, and only Hero Defense (moves) and the visibility test (actions) have
    /// an input to submit.
    static func refusal(_ config: BenchmarkConfig) -> String? {
        if config.actionsPerPlayer > 0 {
            let unsupported = [
                (config.gameType != .visibilityTest, "--game-type other than visibility-test"),
                (!config.inputsFromWire, "runs without --inputs-from-wire (actions are sent as client frames)"),
            ].filter(\.0).map(\.1)
            if !unsupported.isEmpty {
                return "--actions-per-player doesn't support \(unsupported.joined(separator: ", "))"
            }
        }
        guard config.inputsFromWire else { return nil }
        let unsupported = [
            (config.parallel || config.compareParallel, "parallel runs (pass --parallel false)"),
            (config.scalabilityTest, "--scalability"),
            (config.hashCost, "--hash-cost"),
            (config.compareWorkerPool, "--compare-worker-pool"),
            (config.useWorkerPool, "--use-worker-pool"),
            (config.joinThroughRouter, "--join-through-router on"),
            (config.gameType == .cardGame, "--game-type card-game (it has no input to send)"),
            (config.gameType == .heroDefense && !config.activePlayers, "hero-defense without --active-players (the moves are its inputs)"),
            // Hero-defense applies a MoveTo event on its next tick: with no tick, none is applied.
            (config.gameType == .heroDefense && config.ticksPerSync == 0, "hero-defense with --ticks-per-sync 0 (moves are applied on ticks)"),
            (config.gameType == .visibilityTest && config.actionsPerPlayer == 0, "visibility-test without --actions-per-player"),
        ].filter(\.0).map(\.1)
        guard unsupported.isEmpty else {
            return "--inputs-from-wire doesn't support \(unsupported.joined(separator: ", "))"
        }
        return nil
    }
}

// MARK: - Client frames

/// Client frames as the TypeScript SDK sends them (`sdk/ts/src/core/protocol.ts`, `encodeMessage`
/// and `encodeMessageArray`): the JSON object form, or `[kind, ...]` with the payload as a map, in
/// JSON or MessagePack. The client never sends a positional payload.
enum ClientFrames {
    static func event(type: String, payload: AnyCodable, encoding: TransportEncoding) throws -> Data {
        switch encoding {
        case .json:
            let message = TransportMessage.event(event: .fromClient(event: AnyClientEvent(type: type, payload: payload)))
            return try JSONEncoder().encode(message)
        case .opcodeJsonArray:
            let body = try foundationObject(payload)
            let array: [Any] = [MessageKindOpcode.event.rawValue, 0, type, body]
            return try JSONSerialization.data(withJSONObject: array)
        case .messagepack:
            let body = try MessagePackValueEncoder().encode(payload)
            return try pack(.array([.int(Int64(MessageKindOpcode.event.rawValue)), .int(0), .string(type), body]))
        }
    }

    static func action(requestID: String, typeIdentifier: String, payload: AnyCodable, encoding: TransportEncoding) throws -> Data {
        switch encoding {
        case .json:
            let message = TransportMessage.action(
                requestID: requestID,
                action: ActionEnvelope(typeIdentifier: typeIdentifier, payload: payload))
            return try JSONEncoder().encode(message)
        case .opcodeJsonArray:
            let body = try foundationObject(payload)
            let array: [Any] = [MessageKindOpcode.action.rawValue, requestID, typeIdentifier, body]
            return try JSONSerialization.data(withJSONObject: array)
        case .messagepack:
            let body = try MessagePackValueEncoder().encode(payload)
            return try pack(.array([.int(Int64(MessageKindOpcode.action.rawValue)), .string(requestID), .string(typeIdentifier), body]))
        }
    }

    /// A value's JSON tree as Foundation objects, for `JSONSerialization`.
    private static func foundationObject(_ value: AnyCodable) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
    }
}

/// The run's client frames, built outside the timed spans: one iteration's frames per room and
/// player, in submission order.
struct WireInputs {
    let encoding: TransportEncoding
    /// Each room's sessions, by player index (the benchmark's own IDs, as the joins used).
    let sessions: [[SessionID]]
    let actionsPerPlayer: Int

    init(roomCount: Int, playersPerRoom: Int, encoding: TransportEncoding, actionsPerPlayer: Int) {
        self.encoding = encoding
        self.actionsPerPlayer = actionsPerPlayer
        sessions = (0 ..< roomCount).map { roomIndex in
            (0 ..< playersPerRoom).map { SessionID("room\(roomIndex)-session-\($0)") }
        }
    }

    /// Inputs one iteration submits to one room: rooms × this is the run's expected count.
    var inputsPerRoomIteration: Int {
        sessions.first.map { $0.count * max(actionsPerPlayer, 1) } ?? 0
    }

    /// Hero Defense: each player's move for `iteration`, the same targets
    /// `injectActiveMoveTargets` sends. One list serves every room (the targets don't depend on
    /// the room).
    func moveFrames(iteration: Int) -> [Data] {
        let playersPerRoom = sessions.first?.count ?? 0
        return (0 ..< playersPerRoom).map { playerIndex in
            let tx = Float((playerIndex * 37 + iteration * 13) % 128)
            let ty = Float((playerIndex * 53 + iteration * 17) % 72)
            do {
                let payload = try JSONDecoder().decode(AnyCodable.self, from: JSONEncoder().encode(MoveToEvent(x: tx, y: ty)))
                return try ClientFrames.event(type: "MoveTo", payload: payload, encoding: encoding)
            } catch {
                fatalError("--inputs-from-wire: can't encode a MoveTo frame: \(error)")
            }
        }
    }

    /// Visibility test: `actionsPerPlayer` `SetMotionAction(enabled: true)` frames per player for
    /// `iteration` in room `roomIndex`, with a request ID unique in the run. Motion is on from the
    /// start, so they leave the state as it is.
    func actionFrames(roomIndex: Int, iteration: Int) -> [(session: SessionID, frame: Data)] {
        do {
            let payload = try JSONDecoder().decode(AnyCodable.self, from: JSONEncoder().encode(SetMotionAction(enabled: true)))
            var frames: [(session: SessionID, frame: Data)] = []
            for (playerIndex, session) in sessions[roomIndex].enumerated() {
                for k in 0 ..< actionsPerPlayer {
                    let requestID = "r\(roomIndex)-p\(playerIndex)-i\(iteration)-k\(k)"
                    let frame = try ClientFrames.action(
                        requestID: requestID, typeIdentifier: "SetMotion", payload: payload, encoding: encoding)
                    frames.append((session, frame))
                }
            }
            return frames
        } catch {
            fatalError("--inputs-from-wire: can't encode a SetMotion frame: \(error)")
        }
    }
}

// MARK: - Counts

/// A run's inputs: handed to the adapter, refused with an error frame, and applied by a
/// handler. The summary requires submitted, accepted and applied all equal to the expected count.
struct InputCounts {
    var submitted = 0
    /// Error frames the server sent during the measured iterations.
    var rejected = 0
    /// `InputProbe.applied` over every room, measured iterations only.
    var applied = 0
    let expected: Int

    var accepted: Int { submitted - rejected }

    var json: [String: Any] {
        ["submitted": submitted, "accepted": accepted, "rejected": rejected, "applied": applied, "expected": expected]
    }

    /// Exits with a message when any count differs from the expected one: a run whose inputs
    /// didn't all arrive and apply isn't the workload asked for.
    func requireComplete(label: String) {
        guard submitted != expected || accepted != expected || applied != expected else { return }
        try? FileHandle.standardError.write(contentsOf: Data(
            "error: \(label): inputs submitted \(submitted), accepted \(accepted) (rejected \(rejected)), applied \(applied); expected \(expected) each\n".utf8))
        exit(1)
    }
}
