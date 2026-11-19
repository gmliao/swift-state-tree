// Tests/SwiftStateTreeNIOTests/Differential/DiffModel.swift
//
// The differential harness's data (#555): cells, scenarios and their steps, and the decoded
// value the golden files store beside each frame's bytes.

#if DEBUG
import Foundation
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport
import SwiftStateTreeMessagePack

// MARK: - Cells

/// In-turn sync on or off for the land's manager.
enum DiffSyncMode: String, CaseIterable, Codable, Sendable, Comparable {
    case inTurn = "inturn"
    case legacy

    var inTurnSync: Bool { self == .inTurn }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The transport encoding, one of the three presets a server runs.
enum DiffEncoding: String, CaseIterable, Codable, Sendable, Comparable {
    case json
    case opcode
    case messagepack

    var config: TransportEncodingConfig {
        switch self {
        case .json: return .json
        case .opcode: return .opcode
        case .messagepack: return .messagepack
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One cell of the matrix: a scenario runs once per cell its rule names.
struct DiffCell: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    let sync: DiffSyncMode
    let encoding: DiffEncoding
    let land: DiffLandKind

    /// `<sync>.<encoding>.<land>`, the cell part of a golden's file name.
    var description: String { "\(sync.rawValue).\(encoding.rawValue).\(land.rawValue)" }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.description < rhs.description }
}

/// The sync modes and land kinds a scenario applies to; it runs with every encoding in each.
struct DiffCellRule: Sendable {
    let syncModes: [DiffSyncMode]
    let landKinds: [DiffLandKind]

    static let all = DiffCellRule(syncModes: DiffSyncMode.allCases, landKinds: DiffLandKind.allCases)
    static let inTurnOnly = DiffCellRule(syncModes: [.inTurn], landKinds: DiffLandKind.allCases)
    static let legacyOnly = DiffCellRule(syncModes: [.legacy], landKinds: DiffLandKind.allCases)

    /// Every cell of the rule, before any mask.
    var cells: [DiffCell] {
        syncModes.flatMap { sync in
            DiffEncoding.allCases.flatMap { encoding in
                landKinds.map { DiffCell(sync: sync, encoding: encoding, land: $0) }
            }
        }.sorted()
    }
}

// MARK: - Scenarios

/// A hold point of a neighbour or of the adapter, by component.
enum DiffHold: Hashable, Sendable, CustomStringConvertible {
    case router(LandRouterHoldPoint)
    case adapter(TransportAdapterHoldPoint)
    case keeper(LandKeeperHoldPoint)

    var description: String {
        switch self {
        case .router(let point): return "router.\(point)"
        case .adapter(let point): return "adapter.\(point)"
        case .keeper(let point): return "keeper.\(point)"
        }
    }
}

/// One step of a scenario. The runner runs them in order; each waits for the milestone that
/// makes its work done before the next starts (the step rule, plan rev 10).
enum DiffStep: Sendable {
    /// A new connection attempt `name` with the `SessionID` `session`.
    case connect(String, session: String)
    /// `name` joins as `player` and the join settles: its join reply, its flip and (on a tick
    /// land) the one tick that applies its OnJoin.
    case join(String, player: String)
    /// `name` sends a join that the land refuses; the runner waits for its error frame.
    case refusedJoin(String, player: String)
    /// `name` sends a join and the runner doesn't wait: a race row's join, settled by
    /// `awaitJoin` after its holds are released.
    case startJoin(String, player: String)
    /// Waits for a started join's ingress to finish and its flip to settle.
    case awaitJoin(String)
    /// `name` sends a `DiffBumpAction`; the runner waits for its reply (a tick land steps one
    /// tick to apply it).
    case bump(String, requestID: String, amount: Int)
    /// `name` sends a `DiffHeldAction` whose resolver waits on gate `key`; the runner waits for
    /// the resolver's arrival.
    case held(String, requestID: String, key: Int)
    /// Opens resolver gate `key`.
    case openGate(Int)
    /// One tick and the sync cycle after it (a tick land only; nothing on a tickless one).
    case tick
    /// The transport's own disconnect of `name`, awaited, then its forward to the adapter and
    /// the leave applied (a tick and the sync cycle on a tick land).
    case disconnect(String)
    /// Holds the code at `hold`, on its `arrival`-th arrival (nil: every arrival).
    case arm(DiffHold, arrival: Int? = nil)
    /// Notes arrivals at `hold` without blocking them, from now on.
    case observe(DiffHold)
    /// Waits until `hold` was reached `count` times since it was armed or observed. A hold that
    /// isn't reached fails the run with its name (the reach rule).
    case reach(DiffHold, count: Int = 1)
    /// Releases an armed hold.
    case release(DiffHold)
    /// The live checkpoint: the barrier, then the live capture and the convergence check.
    case liveCheckpoint
    /// Stops the land and waits for its stop to finish.
    case stop
    /// A row's post-condition, or an action no other step covers; named in failures.
    case check(String, @Sendable (DiffRun) async throws -> Void)
}

/// What a request should get, per connection attempt (the property oracle, plan §5.6).
enum DiffOutcome: Sendable, Equatable {
    /// One reply to the request.
    case reply
    /// One error frame correlated with the request.
    case error
    /// Neither a reply nor an error, on any connection.
    case none
}

struct DiffScenario: Sendable {
    let name: String
    let cells: DiffCellRule
    let steps: [DiffStep]
    /// Every request the scenario sends, with its expected outcome.
    let outcomes: [String: DiffOutcome]
    /// The lifecycle the record must hold: each player's joins and leaves, in order.
    let lifecycle: [String: [DiffLifecycle]]
}

enum DiffLifecycle: String, Sendable, Codable {
    case join
    case leave
}

// MARK: - Decoded values

/// A decoded value as the golden files store it: JSON, with MessagePack's binary and
/// extension values kept apart.
indirect enum DiffValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    case string(String)
    case binary(Data)
    case array([DiffValue])
    case object([String: DiffValue])
    /// A MessagePack map with non-string keys: its entries in order.
    case pairs([[DiffValue]])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let object = try? container.decode([String: DiffValue].self) {
            if object.count == 1, let tagged = Self.untag(object) { self = tagged; return }
            self = .object(object)
            return
        }
        if let array = try? container.decode([DiffValue].self) { self = .array(array); return }
        if let bool = try? container.decode(Bool.self) { self = .bool(bool); return }
        if let int = try? container.decode(Int64.self) { self = .int(int); return }
        if let uint = try? container.decode(UInt64.self) { self = .uint(uint); return }
        if let double = try? container.decode(Double.self) { self = .double(double); return }
        self = .string(try container.decode(String.self))
    }

    /// The tagged forms (`{"$binary": ...}`, `{"$pairs": ...}`, `{"$double": ...}`, `{"$uint": ...}`)
    /// keep a value's kind across a JSON round trip.
    private static func untag(_ object: [String: DiffValue]) -> DiffValue? {
        guard let (key, value) = object.first else { return nil }
        switch (key, value) {
        case ("$binary", .string(let base64)): return Data(base64Encoded: base64).map(DiffValue.binary)
        case ("$pairs", .array(let entries)):
            var pairs: [[DiffValue]] = []
            for entry in entries {
                guard case .array(let pair) = entry, pair.count == 2 else { return nil }
                pairs.append(pair)
            }
            return .pairs(pairs)
        case ("$double", .string(let text)): return Double(text).map(DiffValue.double)
        case ("$uint", .string(let text)): return UInt64(text).map(DiffValue.uint)
        default: return nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        // Tagged: a JSON number would read back as an int, or round.
        case .uint(let value): try container.encode(["$uint": String(value)])
        case .double(let value): try container.encode(["$double": String(value)])
        case .string(let value): try container.encode(value)
        case .binary(let data): try container.encode(["$binary": data.base64EncodedString()])
        case .array(let items): try container.encode(items)
        case .object(let fields): try container.encode(fields)
        case .pairs(let pairs): try container.encode(["$pairs": DiffValue.array(pairs.map(DiffValue.array))])
        }
    }

    /// A frame's decoded view: JSON when its bytes are JSON, else MessagePack.
    static func decodeFrame(_ data: Data) throws -> DiffValue {
        if let first = data.first, first == UInt8(ascii: "{") || first == UInt8(ascii: "[") {
            return .object(["json": try fromJSON(data)])
        }
        return .object(["msgpack": from(try unpack(data))])
    }

    /// Sorted-key JSON text of a value, for ordering and for reports.
    static func canonicalText(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "<unencodable>"
    }

    static func fromJSON(_ data: Data) throws -> DiffValue {
        from(json: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    private static func from(json: Any) -> DiffValue {
        switch json {
        case is NSNull: return .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            if CFNumberIsFloatType(number) { return .double(number.doubleValue) }
            if number.int64Value >= 0, number.uint64Value > UInt64(Int64.max) { return .uint(number.uint64Value) }
            return .int(number.int64Value)
        case let string as String: return .string(string)
        case let array as [Any]: return .array(array.map { from(json: $0) })
        case let object as [String: Any]: return .object(object.mapValues { from(json: $0) })
        default: return .string(String(describing: json))
        }
    }

    private static func from(_ value: MessagePackValue) -> DiffValue {
        switch value {
        case .nil: return .null
        case .bool(let value): return .bool(value)
        case .int(let value): return .int(value)
        case .uint(let value): return value <= UInt64(Int64.max) ? .int(Int64(value)) : .uint(value)
        case .float(let value): return .double(Double(value))
        case .double(let value): return .double(value)
        case .string(let value): return .string(value)
        case .binary(let data): return .binary(data)
        case .array(let items): return .array(items.map(from))
        case .map(let entries):
            var object: [String: DiffValue] = [:]
            var allStrings = true
            for (key, entry) in entries {
                guard case .string(let name) = key, object[name] == nil else { allStrings = false; break }
                object[name] = from(entry)
            }
            if allStrings { return .object(object) }
            // A decoded map has no order (per-process hash seeds): sort its entries by their
            // canonical JSON, so the view doesn't depend on the process.
            let pairs = entries.map { [from($0.key), from($0.value)] }
            return .pairs(pairs.sorted { canonicalText($0) < canonicalText($1) })
        case .extended(let type, let data): return .object(["$ext": .array([.int(Int64(type)), .binary(data)])])
        }
    }
}
#endif
