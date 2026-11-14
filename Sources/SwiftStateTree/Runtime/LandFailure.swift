import Foundation

/// Why a land was ended by a failure (#535).
///
/// A sync conversion, a frame or event encode, a sync plan, or a handler that threw after
/// writing synced state can't be brought back to a fully correct state, so the land ends: its
/// sessions close with 4016 (`landFailed`), and its destroy handlers and save see
/// `LandDestructionCause.failed`. The keeper keeps the first failure (`LandKeeper.failure`).
public struct LandFailure: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Kind: String, Sendable, Codable {
        /// A synced value didn't convert.
        case syncConversion
        /// A state frame didn't encode.
        case syncEncode
        /// A sync plan threw (#535 row 15: the first throw ends the land).
        case syncPlan
        /// A server event didn't encode.
        case eventEncode
        /// A handler threw after mutable access to synced state (#87).
        case handlerWrite
    }

    public let kind: Kind
    /// The root field, when known.
    public let field: String?
    /// The error's text.
    public let detail: String
    /// Where the land stopped.
    public let position: LandFailurePosition

    public init(kind: Kind, field: String? = nil, detail: String, position: LandFailurePosition) {
        self.kind = kind
        self.field = field
        self.detail = detail
        self.position = position
    }

    public var description: String {
        var text = "land failed (\(kind.rawValue)"
        if let field { text += ", field \(field)" }
        text += " at \(position)): \(detail)"
        return text
    }
}

/// Where in the land's input stream a failure stopped it (#535).
public struct LandFailurePosition: Sendable, Equatable, Codable, CustomStringConvertible {
    public enum Stage: String, Sendable, Codable {
        /// While applying the input `sequence`; later inputs weren't applied.
        case input
        /// In the tick handler (reserved for #87's undo log; not produced today).
        case tickHandler
        /// After the turn's inputs and tick handler, in its sync phase.
        case syncPhase
        /// In the legacy event flush after the turn.
        case eventFlush
    }

    /// The tick of the turn, for a tick land.
    public let tickId: Int64?
    /// The pass, for a tickless land.
    public let pass: Int?
    /// The input applied when the failure happened, for `.input`.
    public let sequence: Int64?
    public let stage: Stage

    public init(tickId: Int64? = nil, pass: Int? = nil, sequence: Int64? = nil, stage: Stage) {
        self.tickId = tickId
        self.pass = pass
        self.sequence = sequence
        self.stage = stage
    }

    public var description: String {
        var parts: [String] = [stage.rawValue]
        if let tickId { parts.append("tick \(tickId)") }
        if let pass { parts.append("pass \(pass)") }
        if let sequence { parts.append("sequence \(sequence)") }
        return parts.joined(separator: ", ")
    }
}
