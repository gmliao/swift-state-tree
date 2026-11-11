// Tests/SwiftStateTreeTests/SyncLeafWritableTests.swift
//
// The typed leaf forms (`SyncLeafWritable`, #392 PR E part 1) against the conversions they stand
// in for: for every type in the writer set, the typed snapshot is exactly both forms the macro
// emits, the typed change test is `sameValue` of the converted values, and today's diff of two
// converted values is one set exactly when they aren't the same. Then which registrations take
// the leaf form, and the release guard on a mislabelled one.

import Foundation
import Testing
@testable import SwiftStateTree
import SwiftStateTreeDeterministicMath

// MARK: - States

enum LeafKind: String, Equatable, Sendable, Codable {
    case a, b
}

/// A user's own convertible type: not in the writer set.
struct LeafCustom: Equatable, Sendable, SnapshotValueConvertible {
    var n: Int = 0
    func toSnapshotValue() throws -> SnapshotValue { .object(["n": .int(n)]) }
}

typealias LeafScore = Int

@StateNodeBuilder
struct LeafFields: StateNodeProtocol {
    @Sync(.broadcast) var flag: Bool = false
    @Sync(.broadcast) var count: Int = 0
    @Sync(.broadcast) var small: Int8 = 0
    @Sync(.broadcast) var tick: Int64 = 0
    @Sync(.broadcast) var big: UInt64 = 0
    @Sync(.broadcast) var ratio: Double = 0
    @Sync(.broadcast) var progress: Float = 0
    @Sync(.broadcast) var name: String = ""
    @Sync(.broadcast) var owner: PlayerID? = nil
    @Sync(.broadcast) var client: ClientID = ClientID("c")
    @Sync(.broadcast) var session: SessionID? = nil
    @Sync(.broadcast) var land: LandID = LandID("a:b")
    @Sync(.broadcast) var at: Position2 = Position2(x: 0, y: 0)
    @Sync(.broadcast) var target: Position2? = nil
    @Sync(.broadcast) var turn: Angle = Angle(degrees: 0)
    @Sync(.broadcast) var velocity: Velocity2 = Velocity2(x: 0, y: 0)
    @Sync(.broadcast) var cell: IVec2 = IVec2(x: 0, y: 0)
    // Spellings the macro converts with `make(from:)`.
    @Sync(.broadcast) var score: LeafScore = 0
    @Sync(.broadcast) var qualified: Swift.Int = 0
    // Not in the writer set.
    @Sync(.broadcast) var list: [Int] = []
    @Sync(.broadcast) var custom: LeafCustom = LeafCustom()
    @Sync(.broadcast) var kind: LeafKind = LeafKind.a
    @Sync(.broadcast) var values: [String: Int] = [:]
}

/// A generic holder: its field's static type is `T?`, so the macro converts it with
/// `make(from: value as Any)` and the registration sees the real type at run time.
@StateNodeBuilder
struct LeafGenericBox<T: Equatable & Sendable>: StateNodeProtocol {
    @Sync(.broadcast) var value: T? = nil
}

@StateNodeBuilder
struct LeafRow: StateNodeProtocol {
    @Sync(.broadcast) var hp: Int = 0
    @Sync(.broadcast) var at: Position2 = Position2(x: 0, y: 0)
    @Sync(.broadcast) var target: Position2? = nil
}

@StateNodeBuilder
struct LeafRoot: StateNodeProtocol {
    @Sync(.broadcast) var rows: [Int: LeafRow] = [:]
    @Sync(.broadcast) var fields: LeafFields = LeafFields()
    @Sync(.broadcast) var intBox: LeafGenericBox<Int> = LeafGenericBox<Int>()
    @Sync(.broadcast) var positionBox: LeafGenericBox<Position2> = LeafGenericBox<Position2>()
}

/// A hand registration of an `Int` field that writes it as a string.
struct LeafMislabelled: StateNodeProtocol {
    var n: Int = 0
    init() {}
    func getSyncFields() -> [SyncFieldInfo] { [] }
    static func getFieldMetadata() -> [FieldMetadata] { [] }
    func validateSyncFields() -> Bool { true }
    func snapshot(for playerID: PlayerID?, dirtyFields: Set<String>?) throws -> StateSnapshot { StateSnapshot(values: ["n": .string(String(n))]) }
    func broadcastSnapshot(dirtyFields: Set<String>?) throws -> StateSnapshot { try snapshot(for: nil, dirtyFields: dirtyFields) }
    func fullStateSnapshot() throws -> StateSnapshot { try snapshot(for: nil, dirtyFields: nil) }
    func isDirty() -> Bool { true }
    func getDirtyFields() -> Set<String> { ["n"] }
    func clearDirty() {}
    static var hasPlayerDependentSyncFields: Bool { false }
    nonisolated(unsafe) static var conversion = SyncTableConversion.standard
    static func _syncTableFields() -> [SyncTableField<LeafMislabelled>]? {
        [SyncTableField<LeafMislabelled>.make(
            name: "n", policy: .broadcast, conversion: conversion,
            read: { $0.n }, convert: { .string(String($0)) }
        )]
    }
}

/// A hand-written node with no field metadata, so no layout node: its `Position2` field, though
/// registered with the standard conversion, has no atomic node at its path, and today's diff
/// patches it per component.
struct LeafNoLayout: StateNodeProtocol {
    var at = Position2(x: 0, y: 0)
    init() {}
    func getSyncFields() -> [SyncFieldInfo] { [] }
    static func getFieldMetadata() -> [FieldMetadata] { [] }
    func validateSyncFields() -> Bool { true }
    func snapshot(for playerID: PlayerID?, dirtyFields: Set<String>?) throws -> StateSnapshot { StateSnapshot(values: ["at": try at.toSnapshotValue()]) }
    func broadcastSnapshot(dirtyFields: Set<String>?) throws -> StateSnapshot { try snapshot(for: nil, dirtyFields: dirtyFields) }
    func fullStateSnapshot() throws -> StateSnapshot { try snapshot(for: nil, dirtyFields: nil) }
    func isDirty() -> Bool { true }
    func getDirtyFields() -> Set<String> { ["at"] }
    func clearDirty() {}
    static var hasPlayerDependentSyncFields: Bool { false }
    static func _syncTableFields() -> [SyncTableField<LeafNoLayout>]? {
        [SyncTableField<LeafNoLayout>.make(
            name: "at", policy: .broadcast, conversion: .standard,
            read: { $0.at }, convert: { try SnapshotValue.make(from: $0) }
        )]
    }
}

// MARK: - Helpers

/// The same value, as bytes on the wire would show it: a `Double` by its bits, a `String` by
/// its UTF-8 (two canonically equivalent spellings are equal `String`s but differ on the wire).
private func exact(_ lhs: SnapshotValue, _ rhs: SnapshotValue) -> Bool {
    switch (lhs, rhs) {
    case (.null, .null): return true
    case (.bool(let a), .bool(let b)): return a == b
    case (.int(let a), .int(let b)): return a == b
    case (.double(let a), .double(let b)): return a.bitPattern == b.bitPattern
    case (.string(let a), .string(let b)): return a.utf8.elementsEqual(b.utf8)
    case (.array(let a), .array(let b)): return a.count == b.count && zip(a, b).allSatisfy { exact($0, $1) }
    case (.object(let a), .object(let b)):
        guard a.count == b.count else { return false }
        return a.allSatisfy { key, value in
            guard let pair = b.first(where: { $0.key.utf8.elementsEqual(key.utf8) }) else { return false }
            return exact(value, pair.value)
        }
    default: return false
    }
}

/// Checks one writer type over `values`:
/// - its typed snapshot is exactly `direct` (the macro's direct form, when it has one) and
///   `make(from:)` of the value, boxed or not, and of the value as an optional;
/// - its change test is `sameValue` of the converted values, for every pair;
/// - today's diff of two converted values is one set of the new one when they aren't the same,
///   else nothing (`layout` is the field's layout node, for an atomic type).
private func checkWriter<T: SyncLeafWritable>(
    _ values: [T],
    direct: ((T) -> SnapshotValue)? = nil,
    layout: AtomicLayoutTable.Node? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    for value in values {
        let typed = value.syncLeafSnapshot
        if let direct {
            #expect(exact(typed, direct(value)), "\(T.self) \(value): \(typed) vs direct \(direct(value))", sourceLocation: sourceLocation)
        }
        let made = try SnapshotValue.make(from: value)
        let boxed = try SnapshotValue.make(from: value as Any)
        let optional = try SnapshotValue.make(from: Optional(value) as Any)
        #expect(exact(typed, made), "\(T.self) \(value): \(typed) vs make(from:) \(made)", sourceLocation: sourceLocation)
        #expect(exact(typed, boxed), "\(T.self) \(value): \(typed) vs make(from: as Any) \(boxed)", sourceLocation: sourceLocation)
        #expect(exact(Optional(value).syncLeafSnapshot, optional), "\(T.self)? \(value)", sourceLocation: sourceLocation)
    }
    #expect(exact(T?.none.syncLeafSnapshot, try SnapshotValue.make(from: T?.none as Any)), sourceLocation: sourceLocation)
    let optionals = values.map { Optional($0) } + [nil]
    for a in optionals {
        for b in optionals {
            let ca = try SnapshotValue.make(from: a as Any), cb = try SnapshotValue.make(from: b as Any)
            let same = SnapshotValue.sameValue(ca, cb)
            #expect(T?.syncLeafSame(a, b) == same, "\(T.self)? same(\(String(describing: a)), \(String(describing: b)))", sourceLocation: sourceLocation)
            if let a, let b {
                #expect(T.syncLeafSame(a, b) == same, "\(T.self) same(\(a), \(b))", sourceLocation: sourceLocation)
            }
            let patches = SyncEngine.diffSnapshotValues(from: ca, to: cb, basePath: "/f", layout: layout)
            if same {
                #expect(patches.isEmpty, "\(T.self)? \(String(describing: a)) -> \(String(describing: b)): \(patches)", sourceLocation: sourceLocation)
            } else {
                #expect(patches.count == 1 && patches[0].path == "/f", "\(T.self)? \(String(describing: a)) -> \(String(describing: b)): \(patches)", sourceLocation: sourceLocation)
                if case .set(let set)? = patches.first?.operation {
                    #expect(exact(set, cb), sourceLocation: sourceLocation)
                } else {
                    Issue.record("\(T.self)?: not a set: \(patches)", sourceLocation: sourceLocation)
                }
            }
        }
    }
}

private let doubles: [Double] = [
    0, -0.0, 1, -1, 0.1, .nan, -.nan, .infinity, -.infinity, .leastNonzeroMagnitude,
    .greatestFiniteMagnitude, Double(Float.greatestFiniteMagnitude), 1e300,
]
private let floats: [Float] = [0, -0.0, 1, -1, 0.1, .nan, .infinity, -.infinity, .leastNonzeroMagnitude, .greatestFiniteMagnitude]
private let strings = ["", "a", "\u{E9}", "e\u{301}", "\u{1F600}", "a:b", String(repeating: "x", count: 1024)]

/// The layout node of `field` in `State`.
private func layoutNode<State: StateNodeProtocol>(_: State.Type, _ path: String...) -> AtomicLayoutTable.Node? {
    var node = AtomicLayoutTable.forState(State.self).root
    for key in path { node = node?.child(key) }
    return node
}

// MARK: - Tests

@Suite("Typed leaf forms (PR E part 1)")
struct SyncLeafWritableTests {
    @Test("Integers and Bool: both macro forms, the change test, one set")
    func integers() throws {
        try checkWriter([false, true], direct: { .bool($0) })
        try checkWriter([0, 1, -1, Int.min, Int.max], direct: { .int($0) })
        try checkWriter([Int8.min, -1, 0, Int8.max], direct: { .int(Int($0)) })
        try checkWriter([Int16.min, 0, Int16.max], direct: { .int(Int($0)) })
        try checkWriter([Int32.min, 0, Int32.max], direct: { .int(Int($0)) })
        try checkWriter([Int64.min, 0, Int64.max], direct: { .int(Int($0)) })
        try checkWriter([UInt8.min, UInt8.max], direct: { .int(Int($0)) })
        try checkWriter([UInt16.min, UInt16.max], direct: { .int(Int($0)) })
        try checkWriter([UInt32.min, UInt32.max], direct: { .int(Int($0)) })
        // Above `Int.max` an unsigned value is its decimal digits.
        try checkWriter([UInt(0), UInt(Int.max), UInt(Int.max) + 1, UInt.max], direct: { SnapshotValue.unsigned($0) })
        try checkWriter([UInt64(0), UInt64(Int.max), UInt64(Int.max) + 1, UInt64.max], direct: { SnapshotValue.unsigned($0) })
    }

    @Test("Float and Double: NaN is the same as NaN, the bits are kept, Float is widened")
    func floatingPoint() throws {
        try checkWriter(doubles, direct: { .double($0) })
        try checkWriter(floats, direct: { .double(Double($0)) })
        // An unchanged NaN is no change; `==` alone would call it one.
        #expect(Double.syncLeafSame(.nan, .nan))
        #expect(Float.syncLeafSame(.nan, .nan))
        #expect(Double.syncLeafSame(0, -0.0))
    }

    @Test("Strings and IDs: both spellings of a character are kept as given")
    func stringsAndIDs() throws {
        try checkWriter(strings, direct: { .string($0) })
        try checkWriter(strings.map(PlayerID.init), direct: { .string($0.rawValue) })
        try checkWriter(strings.map(ClientID.init), direct: nil)
        try checkWriter(strings.map(SessionID.init), direct: nil)
    }

    @Test("LandID compares its converted form: two different IDs that write one string are the same")
    func landID() throws {
        let colliding = (LandID(landType: "a", instanceId: "b:c"), LandID(landType: "a:b", instanceId: "c"))
        #expect(colliding.0 != colliding.1)
        #expect(LandID.syncLeafSame(colliding.0, colliding.1))
        #expect(Optional<LandID>.syncLeafSame(colliding.0, colliding.1))
        try checkWriter([colliding.0, colliding.1, LandID("x"), LandID(landType: "x", instanceId: "")], direct: nil)
    }

    @Test("DeterministicMath atomic types: the macro's object, one set where the layout is atomic")
    func atomicTypes() throws {
        let positions = [Position2(x: 0, y: 0), Position2(x: -1.5, y: 2), Position2(x: 1000, y: -1000)]
        try checkWriter(positions, layout: layoutNode(LeafFields.self, "at"))
        try checkWriter(positions.map { Velocity2(x: $0.v.x == 0 ? 0 : 1, y: 2) }, layout: layoutNode(LeafFields.self, "velocity"))
        try checkWriter([Angle(degrees: 0), Angle(degrees: 45), Angle(degrees: -720.5)], layout: layoutNode(LeafFields.self, "turn"))
        try checkWriter([IVec2(x: 0, y: 0), IVec2(x: -2_000_000, y: 2_000_000)], layout: layoutNode(LeafFields.self, "cell"))
        try checkWriter([IVec3(x: 0, y: 0, z: 0), IVec3(x: -2_000_000, y: 1, z: 2_000_000)], layout: IVec3LayoutProbe.node)
        try checkWriter([Acceleration2(x: 0, y: 0), Acceleration2(x: 3, y: -3)], layout: IVec3LayoutProbe.accelerationNode)
        // Each one's typed snapshot is its own `toSnapshotValue()`.
        for position in positions { #expect(exact(position.syncLeafSnapshot, try position.toSnapshotValue())) }
        #expect(exact(Angle(degrees: 30).syncLeafSnapshot, try Angle(degrees: 30).toSnapshotValue()))
        #expect(layoutNode(LeafFields.self, "at")?.isAtomic == true)
        #expect(layoutNode(LeafFields.self, "target")?.isAtomic == true)
    }

    @Test("Without an atomic layout node, today's diff of an atomic type is per component")
    func atomicWithoutLayout() throws {
        let a = try Position2(x: 0, y: 0).toSnapshotValue(), b = try Position2(x: 1, y: 0).toSnapshotValue()
        let patches = SyncEngine.diffSnapshotValues(from: a, to: b, basePath: "/f", layout: nil)
        #expect(patches.map(\.path) == ["/f/v/x"])
    }

    @Test("Registration: the writer set with the standard conversion takes the leaf form; nothing else does")
    func registration() {
        let fields = Dictionary(uniqueKeysWithValues: LeafFields._syncTableFields()!.map { ($0.name, $0.leafWritable) })
        let taken = ["flag", "count", "small", "tick", "big", "ratio", "progress", "name", "owner", "client",
                     "session", "land", "at", "target", "turn", "velocity", "cell", "score", "qualified"]
        for name in taken { #expect(fields[name] == true, "\(name)") }
        for name in ["list", "custom", "kind", "values"] { #expect(fields[name] == false, "\(name)") }
        #expect(LeafGenericBox<Int>._syncTableFields()!.map(\.leafWritable) == [true])
        #expect(LeafGenericBox<Position2>._syncTableFields()!.map(\.leafWritable) == [true])
        #expect(LeafGenericBox<[Int]>._syncTableFields()!.map(\.leafWritable) == [false])
        #expect(LeafGenericBox<LeafKind>._syncTableFields()!.map(\.leafWritable) == [false])
        // A row's fields register from its own type, each on its own.
        #expect(LeafRow._syncTableFields()!.map(\.leafWritable) == [true, true, true])
        // A hand registration without the marker keeps today's path.
        let hand = SyncTableField<LeafFields>.make(name: "count", policy: .broadcast, read: { $0.count }, convert: { .int($0) })
        #expect(hand.leafWritable == false)
    }

    @Test("Typed leaves on: the patches equal today's, rows, root fields and generic holders included", arguments: [false, true])
    func patchesEqualToday(typedLeafValues: Bool) throws {
        let typed = SyncTableBroadcastDiff<LeafRoot>(typedLeafValues: typedLeafValues)
        let reference = SyncTableBroadcastDiff<LeafRoot>()
        var state = LeafRoot()
        state.rows[1] = LeafRow()
        var drops = ExtractionDrops()
        typed.seed(state, drops: &drops)
        reference.seed(state, drops: &drops)
        func step(_ change: (inout LeafRoot) -> Void) {
            change(&state)
            var typedDrops = ExtractionDrops(), referenceDrops = ExtractionDrops()
            let (a, stagedA) = typed.diff(state, fields: nil, drops: &typedDrops)
            let (b, stagedB) = reference.diff(state, fields: nil, drops: &referenceDrops)
            #expect(a.count == b.count && zip(a, b).allSatisfy { $0.path == $1.path && $0.operation == $1.operation }, "\(a) vs \(b)")
            typed.apply(stagedA)
            reference.apply(stagedB)
        }
        step { $0.rows[1]!.hp = 3 }
        step { $0.rows[1]!.at = Position2(x: 1, y: 2) }
        step { $0.rows[1]!.target = Position2(x: 5, y: 5) }
        step { $0.rows[1]!.target = nil }
        step { $0.fields.ratio = .nan }
        step { $0.fields.ratio = .nan }
        step { $0.fields.ratio = -0.0 }
        step { $0.fields.land = LandID(landType: "a:b", instanceId: "") }
        step { $0.fields.big = .max }
        step { $0.fields.owner = PlayerID("p") }
        step { $0.intBox.value = 3 }
        step { $0.intBox.value = nil }
        step { $0.positionBox.value = Position2(x: 1, y: 1) }
        step { $0.positionBox.value = Position2(x: 2, y: 1) }
        step { $0.fields.turn = Angle(degrees: 90) }
    }

    @Test("An atomic leaf with no atomic layout node at its path keeps today's per-component patches")
    func atomicLeafWithoutLayoutNode() {
        #expect(AtomicLayoutTable.forState(LeafNoLayout.self).root?.child("at")?.isAtomic != true)
        #expect(LeafNoLayout._syncTableFields()!.map(\.leafWritable) == [true])
        let typed = SyncTableBroadcastDiff<LeafNoLayout>(typedLeafValues: true)
        var state = LeafNoLayout()
        var drops = ExtractionDrops()
        typed.seed(state, drops: &drops)
        state.at = Position2(x: 1, y: 0)
        let (patches, _) = typed.diff(state, fields: nil, drops: &drops)
        #expect(patches.map(\.path) == ["/at/v/x"])
    }

    @Test("A standard registration whose convert isn't the standard one goes back to today's path, reported once")
    func releaseGuard() {
        let reports = LockedReports()
        SyncTableContract.$releaseHandler.withValue({ reports.append($0) }) {
            let typed = SyncTableBroadcastDiff<LeafMislabelled>(typedLeafValues: true)
            var state = LeafMislabelled()
            var drops = ExtractionDrops()
            typed.seed(state, drops: &drops)
            for n in 1...3 {
                state.n = n
                let (patches, staged) = typed.diff(state, fields: nil, drops: &drops)
                // Today's bytes: the field's own convert, a string.
                #expect(patches.map(\.operation) == [.set(.string(String(n)))])
                typed.apply(staged)
            }
        }
        #expect(reports.values.count == 1)
        #expect(reports.values.first?.contains("standard conversion") == true)
    }
}

/// `IVec3` and `Acceleration2` aren't in `LeafFields`; their layout nodes come from this state.
@StateNodeBuilder
struct IVec3LayoutProbe: StateNodeProtocol {
    @Sync(.broadcast) var v3: IVec3 = IVec3(x: 0, y: 0, z: 0)
    @Sync(.broadcast) var acceleration: Acceleration2 = Acceleration2(x: 0, y: 0)

    static var node: AtomicLayoutTable.Node? { AtomicLayoutTable.forState(Self.self).root?.child("v3") }
    static var accelerationNode: AtomicLayoutTable.Node? { AtomicLayoutTable.forState(Self.self).root?.child("acceleration") }
}

private final class LockedReports: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ value: String) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}
