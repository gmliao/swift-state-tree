// Sources/SwiftStateTree/Sync/NestingBudget.swift

import Foundation

/// What a state conversion may still descend into (#716): a value nested too deep, or a cycle
/// through a class, would overflow the thread's stack in a recursive conversion before any later
/// bound refused it, and kill the process with every land on it.
///
/// It holds two counts, carried down by value:
/// - **containers**: the arrays and objects still allowed below this point, on the deepest path.
///   A field's own value is level 1 when it is a container; a scalar adds none. The snapshot
///   object that holds a node's fields isn't counted at the root (it belongs to the frame's
///   overhead), and is counted for a node nested inside a field;
/// - **hops**: the recursive steps that add no container (an `Optional` unwrapped through
///   `Mirror`), which cost a stack frame each.
///
/// A conversion takes the budget at the value it converts. A container's conversion calls
/// `enteringContainer()` once and passes the result to every child; a hop calls `hop()`. Either
/// throws `SyncError.nestingTooDeep` when its count is spent. A tree that is already built (a
/// `SnapshotValue`, or what a hand-written conversion returned) is checked by `check(_:)`, an
/// iterative walk.
public struct NestingBudget: Sendable, Equatable {
    /// The count that ran out.
    public enum Counter: String, Sendable, Equatable {
        case containers
        case hops
    }

    /// The containers allowed below a root field, on the deepest path.
    public static var containerLimit: Int { PayloadNesting.stateMaxDepth }
    /// The recursive steps without a container allowed on one path.
    public static var hopLimit: Int { PayloadNesting.stateMaxHops }

    /// Containers still allowed below this point.
    public private(set) var containersLeft: Int
    /// Hops still allowed below this point.
    public private(set) var hopsLeft: Int
    private let containerLimitValue: Int
    private let hopLimitValue: Int

    /// The budget at a root field's value.
    public init() {
        self.init(containers: Self.containerLimit, hops: Self.hopLimit)
    }

    /// A budget with other limits (tests, and a slot that starts below its root field).
    package init(containers: Int, hops: Int) {
        containersLeft = containers
        hopsLeft = hops
        containerLimitValue = containers
        hopLimitValue = hops
    }

    /// The budget inside a container at this point.
    public func enteringContainer() throws -> NestingBudget {
        guard containersLeft > 0 else { throw refusal(.containers) }
        var inner = self
        inner.containersLeft -= 1
        return inner
    }

    /// The budget after a recursive step that adds no container.
    public func hop() throws -> NestingBudget {
        guard hopsLeft > 0 else { throw refusal(.hops) }
        var next = self
        next.hopsLeft -= 1
        return next
    }

    /// Throws when `value`, taken at this point, holds more containers on one path than are left.
    /// Iterative, so a tree of any depth is checked without recursion.
    public func check(_ value: SnapshotValue) throws {
        var pending: [(value: SnapshotValue, left: Int)] = [(value, containersLeft)]
        while let entry = pending.popLast() {
            let (current, left) = entry
            switch current {
            case .array(let items):
                guard left > 0 else { throw refusal(.containers) }
                for item in items where item.isNestingContainer { pending.append((item, left - 1)) }
            case .object(let fields):
                guard left > 0 else { throw refusal(.containers) }
                for item in fields.values where item.isNestingContainer { pending.append((item, left - 1)) }
            case .null, .bool, .int, .double, .string:
                break
            }
        }
    }

    /// Throws when a node's fields, each taken at this point, hold too many containers.
    public func check(_ snapshot: StateSnapshot) throws {
        for value in snapshot.values.values { try check(value) }
    }

    private func refusal(_ counter: Counter) -> SyncError {
        .nestingTooDeep(counter: counter, limit: counter == .containers ? containerLimitValue : hopLimitValue, field: nil)
    }
}

// MARK: - Test probe

extension NestingBudget {
    /// A step of a conversion that tests count.
    package enum ProbeEvent: Sendable {
        /// `make` converted a typed map of state nodes through its conformance.
        case nodeMap
        /// `make` converted a typed map of convertible values through its conformance.
        case convertibleMap
        /// A budget-aware default checked a conversion's result after it ran.
        case resultCheck
    }

    /// Counts `event` in the probe bound to this task: DEBUG builds only, where an unbound probe
    /// costs one task-local read. Release builds compile it to nothing.
    @inline(__always)
    static func note(_ event: ProbeEvent) {
        #if DEBUG
        probe?.add(event)
        #endif
    }
}

#if DEBUG
extension NestingBudget {
    /// The probe the conversions in this task count into. Tests only: unbound (nil) everywhere
    /// else.
    @TaskLocal package static var probe: Probe?

    /// The counts `probe` keeps, per event.
    package final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [ProbeEvent: Int] = [:]

        package init() {}

        package func count(_ event: ProbeEvent) -> Int {
            lock.lock(); defer { lock.unlock() }
            return counts[event, default: 0]
        }

        func add(_ event: ProbeEvent) {
            lock.lock(); counts[event, default: 0] += 1; lock.unlock()
        }
    }
}
#endif

extension SnapshotValue {
    /// An array or an object: what `NestingBudget` counts.
    var isNestingContainer: Bool {
        switch self {
        case .array, .object: true
        case .null, .bool, .int, .double, .string: false
        }
    }
}
