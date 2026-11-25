import SwiftStateTurns

/// Names an error the keeper holds for a caller that hasn't read it yet (#700 K1b-2).
///
/// The keeper's model holds this, and the error itself stays in a table beside the model: an
/// arbitrary `any Error` isn't plain data. An ID is minted by a keeper-local counter that is never
/// reset or restored from a record, and the counter traps on overflow, so an ID is never reused:
/// a stale ID can't name a newer entry. It isn't an `Error`, so it can't be thrown to a caller by
/// mistake.
@PlainData
package struct FailureID: Hashable, Sendable, CustomStringConvertible {
    package let epoch: Epoch

    package init(_ epoch: Epoch) {
        self.epoch = epoch
    }

    package var description: String { "failure \(epoch.rawValue)" }
}

/// An input's result as the keeper holds it until its caller reads it: the success, or the ID of
/// the failure in the failure table (#700 K1b-2). Not a `Result`: its failure would have to be an
/// `Error`, and `FailureID` deliberately isn't one.
@PlainData
package enum InputResult: Sendable {
    case outcome(InputOutcome)
    case failed(FailureID)
}

/// The error a failure-table lookup returns for an ID the table doesn't hold: a broken invariant
/// (#700 K1b-2). The lookup doesn't trap, in any build: it logs and counts the miss, and the
/// caller gets this error instead of crashing the land.
package struct FailureTableMiss: Error, CustomStringConvertible {
    package let id: FailureID
    package let path: String
    package let sequence: Int64?

    package var description: String {
        "The keeper's failure table has no entry for \(id) (\(path)\(sequence.map { ", sequence \($0)" } ?? ""))"
    }
}
