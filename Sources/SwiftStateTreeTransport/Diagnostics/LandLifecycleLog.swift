// Sources/SwiftStateTreeTransport/Diagnostics/LandLifecycleLog.swift
//
// An opt-in JSON-lines log of land instances: created, removed by ID, destroyed.

import Foundation
import SwiftStateTree

/// One line of the land lifecycle log.
public struct LandLifecycleRecord: Codable, Sendable, Equatable {
    public enum Event: String, Codable, Sendable {
        /// The instance was published under its land ID (joins reach it from now on).
        case created
        /// The instance was removed by ID (`LandManager.removeLand(landID:)`, the admin API's
        /// delete). It isn't destroyed by this: it keeps its players, and logs `destroyed`
        /// when its own destruction ends.
        case removed
        /// The instance's destruction ended (its `onLandDestroyed` reached the manager).
        case destroyed
    }

    public let event: Event
    public let landID: String
    public let landType: String
    /// Process-monotonic: each published instance gets the next number, across every
    /// `LandManager` sharing the log. A land recreated under the same ID gets a new one.
    public let instance: UInt64
    /// The instance's epoch in its `LandManager` (unique per manager only).
    public let epoch: UInt64
    /// Why the destruction started, on `destroyed` lines only.
    public let cause: LandDestructionCause?
    /// Wall clock, milliseconds since 1970: the base of the transport profile's `ts`.
    public let wallMs: Int64
    /// `ProcessInfo.systemUptime`, nanoseconds: a monotonic clock (CLOCK_MONOTONIC on Linux).
    public let uptimeNs: UInt64
}

/// Writes `LandLifecycleRecord` lines. Off by default: `LandManager` logs only when
/// `LAND_LIFECYCLE_LOG_PATH` names a file (`shared`), or when a test installs a log.
///
/// The level filter of the server's logger doesn't apply: measurement runs use
/// `LOG_LEVEL=error`, and enabling this log must not change that configuration.
/// Each line is written synchronously, from the manager's synchronous segment that publishes
/// or removes the instance; lands are created and destroyed rarely, so the cost is one small
/// write per event and nothing on the sync or tick paths.
public final class LandLifecycleLog: @unchecked Sendable {
    private let lock = NSLock()
    private let write: @Sendable (String) -> Void
    private var lastInstance: UInt64 = 0
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// A log that hands each line (without its newline) to `write`.
    init(write: @escaping @Sendable (String) -> Void) {
        self.write = write
    }

    /// The process's log: the file `LAND_LIFECYCLE_LOG_PATH` names, or `nil` when unset.
    public static let shared: LandLifecycleLog? = fromEnvironment(ProcessInfo.processInfo.environment)

    /// A log appending to the file `LAND_LIFECYCLE_LOG_PATH` names in `environment` (created
    /// if missing), or `nil` when the key is unset or the file can't be opened (an empty path
    /// can't be).
    static func fromEnvironment(_ environment: [String: String]) -> LandLifecycleLog? {
        guard let path = environment[TransportEnvKeys.landLifecycleLogPath] else {
            return nil
        }
        if !FileManager.default.fileExists(atPath: path) {
            guard FileManager.default.createFile(atPath: path, contents: nil) else { return nil }
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return nil }
        handle.seekToEndOfFile()
        return LandLifecycleLog(write: { line in
            handle.write(Data((line + "\n").utf8))
        })
    }

    /// The next process-monotonic instance number.
    func nextInstance() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        lastInstance += 1
        return lastInstance
    }

    func log(
        _ event: LandLifecycleRecord.Event,
        landID: LandID,
        instance: UInt64,
        epoch: Epoch,
        cause: LandDestructionCause? = nil
    ) {
        let record = LandLifecycleRecord(
            event: event,
            landID: landID.stringValue,
            landType: landID.landType,
            instance: instance,
            epoch: epoch.rawValue,
            cause: cause,
            wallMs: Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)),
            uptimeNs: UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        )
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? encoder.encode(record), let line = String(data: data, encoding: .utf8) else {
            return
        }
        write(line)
    }
}
