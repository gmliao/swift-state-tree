import Foundation
import Logging

// MARK: - Validate context (#586)

/// A service that a handler's `validate` step may call: it only reads, and the same inputs give
/// the same answer.
///
/// This is a trust contract the compiler can't check. Replay runs `validate` again on the
/// recorded inputs, so a service that answers differently the second time (a clock, a remote
/// call, a random source) makes replay diverge. Load such data in a resolver instead: its output
/// is recorded, and `validate` reads it from the context.
public protocol ReadOnlyLandService: Sendable {}

/// The land's services as `validate` sees them: only types that conform to
/// `ReadOnlyLandService` can be fetched.
///
/// A service registered under an existential type (`register(x, as: (any P).self)`) can't be
/// fetched here, because an existential doesn't conform to the marker. Register it under its
/// concrete type to use it from `validate`.
public struct ReadOnlyLandServices: Sendable {
    private let base: LandServices

    init(_ base: LandServices) {
        self.base = base
    }

    /// The registered service of type `type`, or nil.
    public func get<Service: ReadOnlyLandService>(_ type: Service.Type) -> Service? {
        base.get(type)
    }
}

/// What a handler's `validate` step can see: the input's identity and tick, and the read-only
/// services (#586). Resolver outputs come as `validate`'s typed parameter (#769).
///
/// `validate` decides whether the input may happen and returns the plan `apply` acts on. It can't
/// write the state (it gets it as a constant), emit events, submit server inputs, draw random
/// numbers or request a sync: none of those are on this type.
public struct ValidateContext: Sendable {
    private let base: LandContext

    package init(_ base: LandContext) {
        self.base = base
    }

    /// The land instance's identifier.
    public var landID: String { base.landID }
    /// The player whose input this is (`LandContext.systemPlayerID` for a server input).
    public var playerID: PlayerID { base.playerID }
    /// The client the input came from.
    public var clientID: ClientID { base.clientID }
    /// The session the input came from.
    public var sessionID: SessionID { base.sessionID }
    /// The device identifier the session joined with, if any.
    public var deviceID: String? { base.deviceID }
    /// Whether the player joined as a guest.
    public var isGuest: Bool { base.isGuest }
    /// The metadata the session joined with.
    public var metadata: [String: String] { base.metadata }
    /// The last committed tick, as on `LandContext.tickId`.
    public var tickId: Int64? { base.tickId }
    /// The player's slot, as on `LandContext.playerSlot`.
    public var playerSlot: Int32? { base.playerSlot }
    /// The land's logger. A log line from `validate` is a side effect replay repeats.
    public var logger: Logger { base.logger }
    /// The land's services, restricted to `ReadOnlyLandService` types.
    public var services: ReadOnlyLandServices { ReadOnlyLandServices(base.services) }
}
