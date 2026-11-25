import Foundation
import SwiftStateTurns

/// Why a land was ended by a failure (#535).
///
/// A sync conversion, a frame, event or action-response encode, a sync plan, or a handler that
/// threw after writing synced state can't be brought back to a fully correct state, so the land
/// ends: its sessions close with 4016 (`landFailed`), and its destroy handlers and save see
/// `LandDestructionCause.failed`. The keeper keeps the first failure (`LandKeeper.failure`).
@PlainData
public struct LandFailure: Error, Sendable, Equatable, Codable, CustomStringConvertible {
    @PlainData
    public enum Kind: String, Sendable, Codable {
        /// A synced value didn't convert.
        case syncConversion
        /// A state frame didn't encode.
        case syncEncode
        /// A sync plan threw (#535 row 15: the first throw ends the land).
        case syncPlan
        /// A server event didn't encode.
        case eventEncode
        /// An action's response, or its error reply, didn't encode, so its client would get no
        /// answer (#544, #691).
        case responseEncode
        /// A handler threw after mutable access to synced state (#87). Not produced today: no
        /// handler throws after it writes (#586, #593).
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
@PlainData
public struct LandFailurePosition: Sendable, Equatable, Codable, CustomStringConvertible {
    @PlainData
    public enum Stage: String, Sendable, Codable {
        /// While applying the input `sequence`; later inputs weren't applied.
        case input
        /// In the tick handler (reserved for #87's undo log; not produced today).
        case tickHandler
        /// After the turn's inputs and tick handler, in its sync phase.
        case syncPhase
        /// In the legacy event flush after the turn.
        case eventFlush
        /// After the action's turn, while its response was encoded for the client.
        case actionResponse
    }

    /// The tick of the turn, for a tick land.
    public let tickId: Int64?
    /// The pass, for a tickless land.
    public let pass: Int?
    /// The input applied when the failure happened, for `.input`.
    public let sequence: Int64?
    public let stage: Stage
    /// True when the failure ended the turn that applied it among its inputs: a failure a
    /// transport reported (`submitLandFailure`), applied as an input, ends the batch there. The
    /// turn then ran no tick handler and sent none of its inputs' events (on a tickless land,
    /// set only when that turn's pass, `pass`, applied inputs before it). Replay ends the
    /// recorded tick or pass the same way (record format 3.4). Nil otherwise.
    public let endsInputs: Bool?

    public init(tickId: Int64? = nil, pass: Int? = nil, sequence: Int64? = nil, stage: Stage, endsInputs: Bool? = nil) {
        self.tickId = tickId
        self.pass = pass
        self.sequence = sequence
        self.stage = stage
        self.endsInputs = endsInputs
    }

    public var description: String {
        var parts: [String] = [stage.rawValue]
        if let tickId { parts.append("tick \(tickId)") }
        if let pass { parts.append("pass \(pass)") }
        if let sequence { parts.append("sequence \(sequence)") }
        return parts.joined(separator: ", ")
    }
}
