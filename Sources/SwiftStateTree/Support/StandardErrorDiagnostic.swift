import Foundation

/// Writes `message` to standard error as is (include the newline). A failed write (ENOSPC,
/// EIO, EBADF) drops the message, since a lost diagnostic must not end the process; the
/// non-throwing `FileHandle.write(_:)` would terminate it instead (#263).
///
/// - Parameter handle: standard error by default; tests pass one whose writes fail.
/// - Returns: whether the message was written.
@discardableResult
func writeStandardErrorDiagnostic(_ message: String, to handle: FileHandle = .standardError) -> Bool {
    do {
        try handle.write(contentsOf: Data(message.utf8))
        return true
    } catch {
        return false
    }
}
