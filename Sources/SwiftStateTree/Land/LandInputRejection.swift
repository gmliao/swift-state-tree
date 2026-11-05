// Sources/SwiftStateTree/Land/LandInputRejection.swift

/// Why a keeper rejected a player's input (an action or a client event) at intake. Separate
/// from `LandError`, which is about the Land definition.
public enum LandInputRejection: Error, Sendable, Equatable {
    /// The input comes from a session that a newer join of the same player replaced (one
    /// session per player, newest wins).
    case senderSuperseded
    /// The land is being destroyed: from the moment its drain starts, no input is accepted,
    /// and inputs still pending are dropped (their callers get this).
    case landClosed
}
