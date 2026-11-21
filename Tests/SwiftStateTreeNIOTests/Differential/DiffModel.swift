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

/// The land's sync mode. One case since the adapter's off mode was removed (#546 L2c); it stays
/// so the golden file names (`inturn.<encoding>.<land>`) stay stable.
enum DiffSyncMode: String, CaseIterable, Codable, Sendable, Comparable {
    case inTurn = "inturn"

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
    /// A server stop after its sessions' leaves were submitted and before the keeper's
    /// shutdown (`NIOLandServer`'s after-sessions-closed hook).
    case stopSessionsClosed

    var description: String {
        switch self {
        case .stopSessionsClosed: return "server.stopSessionsClosed"
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
    /// Waits for `name`'s last frame's ingress only: no inputs applied, no flip awaited.
    case awaitIngress(String)
    /// `name` sends a `DiffBumpAction`; the runner waits for its reply (a tick land steps one
    /// tick to apply it).
    case bump(String, requestID: String, amount: Int)
    /// As `bump`, but its change is applied and not synced: the keeper's drain on a tickless
    /// land, one tick on a tick land, with no sync cycle asked for.
    case bumpUnsynced(String, requestID: String, amount: Int)
    /// `name` sends a `DiffHeldAction` whose resolver waits on gate `key`; the runner waits for
    /// the resolver's arrival.
    case held(String, requestID: String, key: Int)
    /// Opens resolver gate `key`.
    case openGate(Int)
    /// Waits until every action job has left the keeper's job table (its result delivered as an
    /// input, or its release), then until every pending answer has been sent, then applies the
    /// inputs. With the loops off, the sync that follows is the runner's: an answer's task and
    /// that sync aren't ordered by anything else, so the answers go first.
    case settleJobs
    /// `settleJobs` without waiting for the answers: for a scenario that holds an answer at
    /// `heldAt` across the sync, so the sync goes first. It first reaches `heldAt`: the answer's
    /// slot is filled, so the pass that applied the job has run, and the sync carries its state
    /// change.
    case settleJobsBeforeAnswers(heldAt: DiffHold)
    /// Waits for every spawned task and the background syncs, then applies the inputs they
    /// queued.
    case settleSpawned
    /// Waits for every spawned task, nothing else.
    case awaitSpawned
    /// The outbound writer is idle and every queued frame reached its connection: before a step
    /// that ends a connection some other way than `disconnect` (a superseding join), or before
    /// a cycle that must find the writer without a backlog.
    case flushOutbound
    /// `steps`, in the cells `label`'s predicate selects; nothing in the others.
    indirect case only(String, @Sendable (DiffCell) -> Bool, [DiffStep])
    /// One tick and the sync cycle after it (a tick land only; nothing on a tickless one).
    case tick
    /// One tick on a tick land, with no sync asked for (nothing on a tickless land).
    case tickUnsynced
    /// The transport's own disconnect of `name`, awaited, then its forward to the adapter and
    /// the leave applied (a tick and the sync cycle on a tick land).
    case disconnect(String)
    /// The transport's disconnect of `name`, awaited, without waiting for its forward: a race
    /// row's disconnect that queues behind a held operation. `settleDisconnects` ends it.
    case startDisconnect(String)
    /// Waits for every disconnect forward, then applies the leaves (as `disconnect` does).
    case settleDisconnects
    /// Waits until no counted disconnect forward is in flight, and applies nothing. It returns
    /// at once when none was started, and it covers forwards counted while it waits. A forward
    /// returns once the adapter's queued leave has returned from the keeper, and on a tickless
    /// land that leave awaits its own input turn. So a later step's sync can't run before that
    /// turn (#676: a legacy sync cycle, removed in #546 L2d-3, then moved the turn's sync
    /// phase into a sync-only turn).
    case awaitDisconnectForwards
    /// Starts the land's stop in a task of its own; `awaitStop` waits for it.
    case startStop
    /// Waits for the started stop; a stop that times out fails the run.
    case awaitStop
    /// Runs `body` in a task of its own, named in failures; the barrier awaits it.
    case spawn(String, @Sendable (DiffRun) async -> Void)
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
    /// A value the row records instead of asserting: it goes into the next checkpoint's capture
    /// under its name, and the comparator compares it (channel `note`). For a state the branch
    /// is meant to change, which a `check` would turn into a run failure there.
    case note(String, @Sendable (DiffRun) async throws -> DiffValue)
}

/// What a request should get, per connection attempt (the property oracle, plan §5.6).
enum DiffOutcome: Sendable, Equatable {
    /// "#" and digits: the reference a `recorded` outcome must carry.
    static func isIssueReference(_ text: String) -> Bool {
        text.count > 1 && text.first == "#" && text.dropFirst().allSatisfy(\.isASCII) && text.dropFirst().allSatisfy(\.isNumber)
    }

    /// One reply to the request.
    case reply
    /// One error frame correlated with the request.
    case error
    /// At most one reply or error, which the oracle doesn't judge: the frames record it and the
    /// comparator compares them. Only for a request whose answer a named issue changes
    /// (`issue`, "#NNN"); the oracle refuses one without it. Listed in the PR that adds it.
    case recorded(issue: String)
    /// Neither a reply nor an error, on any connection.
    case none
}

struct DiffScenario: Sendable {
    let name: String
    let cells: DiffCellRule
    let steps: [DiffStep]
    /// Every request the scenario sends, with its expected outcome.
    let outcomes: [String: DiffOutcome]
    /// Outcomes that differ by cell, replacing `outcomes`' entries there.
    var outcomesByCell: @Sendable (DiffCell) -> [String: DiffOutcome] = { _ in [:] }
    /// The lifecycle the record must hold: each player's joins and leaves, in order.
    let lifecycle: [String: [DiffLifecycle]]
    /// Players whose lifecycle is recorded, not judged, each with the issue that says why: the
    /// oracle skips them, and the record's comparison with the golden covers them (a fix shows
    /// as the record's difference, which the branch lists). A player here has no `lifecycle`
    /// entry.
    let recordedLifecycle: [String: String]

    init(
        name: String, cells: DiffCellRule, steps: [DiffStep], outcomes: [String: DiffOutcome],
        outcomesByCell: @escaping @Sendable (DiffCell) -> [String: DiffOutcome] = { _ in [:] },
        lifecycle: [String: [DiffLifecycle]],
        recordedLifecycle: [String: String] = [:]
    ) {
        self.name = name
        self.cells = cells
        self.steps = steps
        self.outcomes = outcomes
        self.outcomesByCell = outcomesByCell
        self.lifecycle = lifecycle
        self.recordedLifecycle = recordedLifecycle
    }

    func outcomes(in cell: DiffCell) -> [String: DiffOutcome] {
        outcomes.merging(outcomesByCell(cell)) { _, override in override }
    }
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
        try JSONDecoder().decode(JSONTree.self, from: data).value
    }

    /// A JSON value decoded by its token, the same on every platform: `true`/`false` only as a
    /// bool (tried first), a number as a signed integer when it is one, as an unsigned one above
    /// `Int64.max`, and as a double otherwise. Not through `NSNumber`, whose bool and float
    /// tests are CoreFoundation's and differ on Linux.
    private struct JSONTree: Decodable {
        let value: DiffValue

        init(from decoder: Decoder) throws {
            if var array = try? decoder.unkeyedContainer() {
                var items: [DiffValue] = []
                while !array.isAtEnd { items.append(try array.decode(JSONTree.self).value) }
                value = .array(items)
                return
            }
            if let object = try? decoder.container(keyedBy: AnyKey.self) {
                var fields: [String: DiffValue] = [:]
                for key in object.allKeys { fields[key.stringValue] = try object.decode(JSONTree.self, forKey: key).value }
                value = .object(fields)
                return
            }
            let single = try decoder.singleValueContainer()
            if single.decodeNil() { value = .null }
            else if let bool = try? single.decode(Bool.self) { value = .bool(bool) }
            else if let int = try? single.decode(Int64.self) { value = .int(int) }
            else if let uint = try? single.decode(UInt64.self) { value = .uint(uint) }
            else if let double = try? single.decode(Double.self) { value = .double(double) }
            else { value = .string(try single.decode(String.self)) }
        }

        private struct AnyKey: CodingKey {
            let stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { nil }
            init?(intValue: Int) { nil }
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
