import SwiftStateTurns

/// Why a recorded payload didn't decode to its type: kept on the item that holds the payload, so
/// the input fails where a decode at apply would have failed it, with the same error.
///
/// A payload is decoded once, when its item is built (at submit live, from the record in
/// replay), and the item carries the value or this failure. Applying a failed item throws
/// `error`, which rebuilds the error the decode threw: its type for the depth refusals, its text
/// for anything else. Replay reports an input's failure by its text (`String(describing:)`), so
/// the report is the same as a decode at apply gives.
@PlainData
package enum RecordedPayloadDecodeFailure: Error, Equatable, Sendable {
    /// Nested deeper than a transport frame's limit (`PayloadNesting.TooDeep`).
    case tooDeep(limit: Int)
    /// Nested deeper than the record codec's limit (`CanonicalMessagePackError.nestingTooDeep`).
    case recordTooDeep
    /// Any other decode error, by its text.
    case undecodable(String)

    package init(_ error: any Error) {
        if let tooDeep = error as? PayloadNesting.TooDeep {
            self = .tooDeep(limit: tooDeep.limit)
        } else if let codec = error as? CanonicalMessagePackError, codec == .nestingTooDeep {
            self = .recordTooDeep
        } else {
            self = .undecodable(String(describing: error))
        }
    }

    /// The error the decode threw, rebuilt.
    package var error: any Error {
        switch self {
        case .tooDeep(let limit): return PayloadNesting.TooDeep(limit: limit)
        case .recordTooDeep: return CanonicalMessagePackError.nestingTooDeep
        case .undecodable(let text): return RecordedPayloadDecodeError(description: text)
        }
    }
}

/// A recorded payload's decode error other than a depth refusal, by its text: what
/// `RecordedPayloadDecodeFailure.undecodable` rebuilds. Its description is the original error's.
package struct RecordedPayloadDecodeError: Error, CustomStringConvertible, Sendable {
    package let description: String

    package init(description: String) {
        self.description = description
    }
}
