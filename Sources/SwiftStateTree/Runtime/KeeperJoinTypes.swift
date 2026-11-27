// The reporting join's values (#700 K1b-5b §4.1). None depends on the land's state type, so they
// live outside `LandKeeper`: the turn side holds them in a core's input-turn waits (#700 K2-1),
// and the side isn't generic. `LandKeeper` keeps its spellings (`JoinCall`, `JoinDecided`,
// `JoinOutcome`) as typealiases.

/// The reporting join's call.
struct KeeperJoinCall: Sendable {
    let session: PlayerSession
    let clientID: ClientID
    let sessionID: SessionID
    /// The joining session's service overrides: an opaque payload the join carries to its
    /// entry and its resolvers' contexts. No segment calls through it.
    let services: LandServices
    let admitThroughTransport: Bool
}

/// What the reporting join carries from J2's decision on.
struct KeeperJoinDecided: Sendable {
    let call: KeeperJoinCall
    let decision: JoinDecision
    let playerID: PlayerID
    let reservation: Epoch?
}

/// What `joinReportingAdmission` did.
package struct KeeperJoinOutcome: Sendable {
    package let decision: JoinDecision
    /// The transport admitted the session inside the join
    /// (`LandKeeperTransport.admitJoiningSession` returned `true`). When `false`, the caller
    /// admits it after the join returns, so a session is admitted exactly once.
    package let admitted: Bool
    /// The transport refused the join for the player CanJoin resolved, before anything
    /// acted on it (`LandKeeperTransport.refusesResolvedJoin`, #234): nothing changed.
    /// Never set by `decision`, the land's own answer.
    package var refusedStale = false
}
