import SwiftStateTurns

/// A queued action's payload: the value decoded at intake or when replay built the item, or why
/// a recorded one didn't decode (#700 K1b-1, F10).
///
/// It replaces `Result<any ActionPayload, RecordedPayloadDecodeFailure>`. `@PlainData` accepts an
/// existential as an enum payload but not inside `Result`, and the queued items must be plain for
/// `KeeperModel` to be.
@PlainData
package enum DecodedAction: Sendable {
    case value(any ActionPayload)
    case failed(RecordedPayloadDecodeFailure)

    /// The value, or the failure's error: `Result.get`'s meaning.
    package func get() throws -> any ActionPayload {
        switch self {
        case .value(let value): return value
        case .failed(let failure): throw failure.error
        }
    }

    /// The decode's outcome, with its error mapped as replay maps it today.
    package init(catching decode: () throws -> any ActionPayload) {
        do {
            self = .value(try decode())
        } catch {
            self = .failed(RecordedPayloadDecodeFailure(error))
        }
    }
}

/// A queued server input's payload, as `DecodedAction` (#700 K1b-1, F10).
@PlainData
package enum DecodedServerInput: Sendable {
    case value(any ServerInputPayload)
    case failed(RecordedPayloadDecodeFailure)

    /// The value, or the failure's error: `Result.get`'s meaning.
    package func get() throws -> any ServerInputPayload {
        switch self {
        case .value(let value): return value
        case .failed(let failure): throw failure.error
        }
    }

    /// The decode's outcome, with its error mapped as replay maps it today.
    package init(catching decode: () throws -> any ServerInputPayload) {
        do {
            self = .value(try decode())
        } catch {
            self = .failed(RecordedPayloadDecodeFailure(error))
        }
    }
}
