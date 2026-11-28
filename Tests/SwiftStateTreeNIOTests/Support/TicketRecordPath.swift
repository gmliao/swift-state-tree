// Tests/SwiftStateTreeNIOTests/Support/TicketRecordPath.swift

import Foundation

/// The record path a test's replay or monitor ticket names for `file` in `recordsDir`, spelled
/// as `ReevaluationReplaySessionDescriptor.decode`'s containment check spells the directory.
///
/// It creates the directory first (#428). On macOS `standardizedFileURL` drops the `/private`
/// of `/private/tmp` or `/private/var` only for a path that exists. A directory spelled while
/// missing keeps `/private/…`; once another test creates it (the records directory is shared,
/// relative to the cwd by default), the check spells it without, and refuses the ticket. With
/// the directory present at both moments the two spellings agree.
func ticketRecordPath(recordsDir: String, file: String) throws -> String {
    try FileManager.default.createDirectory(atPath: recordsDir, withIntermediateDirectories: true)
    return URL(fileURLWithPath: recordsDir, isDirectory: true).standardizedFileURL.path + "/" + file
}
