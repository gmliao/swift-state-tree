// expect: compiles
import Foundation
import SwiftStateTree
import SwiftStateTurns

// Every attribute the repository puts on a member other than a stored property of a
// @StateNodeBuilder, @SnapshotConvertible, @Payload or @PlainData type, on the member kinds it is
// used on (#837): none adds a declaration, so each passes the member check. A nested type may
// carry this project's macros. `@inlinable` and `@_spi` need public declarations, as in the
// DeterministicMath types and `PlayerID` that use them.
@StateNodeBuilder
struct MembersAllowedState: StateNodeProtocol {
    @Sync(.broadcast)
    var hp: Int = 0
    @TaskLocal static var current: Int = 0

    init() {}

    @available(*, deprecated, message: "use doubled") var twice: Int { hp * 2 }
    @discardableResult mutating func heal() -> Int { hp += 1; return hp }

    @PlainData
    struct Inner: Sendable { var a: Int = 0 }
}

@PlainData
public struct MembersAllowedValue: Sendable {
    @usableFromInline var raw: Int
    @inlinable public static var zero: MembersAllowedValue { MembersAllowedValue(raw: 0) }

    @inlinable public init(raw: Int) { self.raw = raw }
    @_spi(MembersAllowed) public init(fixed raw: Int) { self.raw = raw }

    @inlinable public var doubled: Int { raw * 2 }
    @inlinable public func cost() -> Int { raw }
}

@SnapshotConvertible
struct MembersAllowedSnapshot: Equatable, Sendable {
    var hp: Int = 0
    @available(*, deprecated) var shown: Int { hp }
}

@Payload
struct MembersAllowedEvent: ServerEventPayload {
    let hp: Int
    @available(*, deprecated) var doubled: Int { hp * 2 }
}

@PlainData
enum MembersAllowedPhase: Sendable {
    case lobby
    @available(*, deprecated) case legacy
}
