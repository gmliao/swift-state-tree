import Foundation

// MARK: - Format

/// Record format 3.0 (#245): an append-only log of the records the recorder receives.
///
/// A 6-byte preamble (`SSTR`, major, minor), then records, each a 4-byte big-endian length and
/// one canonical MessagePack map (`CanonicalMessagePack`) with a `kind` key: one `header`, then
/// `turn` records in arrival order, then a `footer` at close. Records for one tick may be spread
/// over several `turn` records; the reader merges them by `tickId` in file order, with the rules
/// of `ReevaluationRecorder.recordTick(_:)`. A file cut anywhere reads up to its last complete
/// record.
///
/// Framing: a tick land's `turn` records follow its ticks (one per tick, plus one per late
/// entry for an older tick); a tickless land's follow its keeper turns (one per turn that
/// recorded anything). Never wall time: with in-turn sync, two recordings of one input are
/// byte-identical (#327). On the legacy path (in-turn sync off) two tickless passes that
/// interleave on the keeper can merge or split their calls differently, by scheduling. Files
/// framed otherwise by earlier 3.0 builds read the same.
///
/// Minor 1 (3.1) adds a tickless land's `passes` to `turn` records (#325, #321); a 3.1
/// reader reads 3.0 files, and a 3.0 reader ignores the key.
public enum ReevaluationRecordLog {
    /// The first four bytes of a 3.x record file.
    public static let magic: [UInt8] = Array("SSTR".utf8)
    /// The major and minor version this build writes.
    public static let formatVersion: (major: UInt8, minor: UInt8) = (3, 2)

    static var preamble: [UInt8] { magic + [formatVersion.major, formatVersion.minor] }

    /// Whether `bytes` start with the 3.x magic.
    public static func hasMagic<C: Collection>(_ bytes: C) -> Bool where C.Element == UInt8 {
        bytes.count >= magic.count && zip(bytes, magic).allSatisfy { $0 == $1 }
    }

    /// `record` encoded and framed (length prefix and body).
    static func framed(_ record: ReevaluationLogRecord) throws -> [UInt8] {
        let body = try CanonicalMessagePack.encode(record)
        guard body.count <= Int(UInt32.max) else { throw CanonicalMessagePackError.lengthTooLarge(body.count) }
        let length = UInt32(body.count)
        return [UInt8(length >> 24), UInt8((length >> 16) & 0xff), UInt8((length >> 8) & 0xff), UInt8(length & 0xff)] + body
    }
}

/// Whether a record file holds everything the recorder received.
public enum ReevaluationRecordCompleteness: Sendable, Equatable {
    /// Closed with every submission applied (a 2.x file is always complete).
    case complete
    /// Closed or copied before everything was written, or cut. `lastTickUnverified` is the
    /// newest tick present when it may be partial; the 3.0 source leaves it out of the replay.
    case incomplete(reason: String, lastTickUnverified: Int64?)

    public var isComplete: Bool { self == .complete }
}

/// One record of a 3.0 file. Fields not used by a kind are absent (nil).
struct ReevaluationLogRecord: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case header, turn, footer }

    var kind: Kind
    // header
    var format: String?
    var codec: String?
    var metadata: ReevaluationRecordMetadata?
    // turn
    var tickId: Int64?
    var stateHash: String?
    var actions: [ReevaluationRecordedAction]?
    var clientEvents: [ReevaluationRecordedClientEvent]?
    var lifecycleEvents: [ReevaluationRecordedLifecycleEvent]?
    var serverEvents: [ReevaluationRecordedServerEvent]?
    var sequenceBeforeInputs: Int64?
    var sequenceBeforeTickHandler: Int64?
    var syncOutputs: [ReevaluationRecordedSyncOutput]?
    var syncMarkers: [ReevaluationRecordedSyncMarker]?
    var initialize: ReevaluationRecordedInitialize?
    var passes: [ReevaluationRecordedPass]?
    var serverInputs: [ReevaluationRecordedServerInput]?
    // footer
    var complete: Bool?
    var maxTickId: Int64?
    var turnCount: Int?
    var syncStreamCount: Int?
    var pendingSubmissions: Int?

    init(kind: Kind) { self.kind = kind }

    static func header(_ metadata: ReevaluationRecordMetadata) -> ReevaluationLogRecord {
        var record = ReevaluationLogRecord(kind: .header)
        record.format = "\(ReevaluationRecordLog.formatVersion.major).\(ReevaluationRecordLog.formatVersion.minor)"
        record.codec = "none"
        record.metadata = metadata
        return record
    }

    /// A `turn` record of `tick` (its state snapshot goes to the side file, not here).
    static func turn(_ tick: ReevaluationTickRecord) -> ReevaluationLogRecord {
        var record = ReevaluationLogRecord(kind: .turn)
        record.tickId = tick.tickId
        record.stateHash = tick.stateHash
        record.actions = tick.actions.nilIfEmpty
        record.clientEvents = tick.clientEvents.nilIfEmpty
        record.lifecycleEvents = tick.lifecycleEvents.nilIfEmpty
        record.serverEvents = tick.serverEvents.nilIfEmpty
        record.sequenceBeforeInputs = tick.sequenceBeforeInputs
        record.sequenceBeforeTickHandler = tick.sequenceBeforeTickHandler
        record.syncOutputs = tick.syncOutputs.nilIfEmpty
        record.syncMarkers = tick.syncMarkers.nilIfEmpty
        record.initialize = tick.initialize
        record.passes = tick.passes.nilIfEmpty
        record.serverInputs = tick.serverInputs.nilIfEmpty
        return record
    }

    var tickRecord: ReevaluationTickRecord? {
        guard kind == .turn, let tickId else { return nil }
        return ReevaluationTickRecord(
            tickId: tickId,
            actions: actions ?? [],
            clientEvents: clientEvents ?? [],
            lifecycleEvents: lifecycleEvents ?? [],
            serverEvents: serverEvents ?? [],
            stateHash: stateHash,
            sequenceBeforeInputs: sequenceBeforeInputs,
            sequenceBeforeTickHandler: sequenceBeforeTickHandler,
            syncOutputs: syncOutputs ?? [],
            syncMarkers: syncMarkers ?? [],
            initialize: initialize,
            passes: passes ?? [],
            serverInputs: serverInputs ?? []
        )
    }
}

private extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}

extension ReevaluationTickRecord {
    /// This record with `later` merged in, as `ReevaluationTickFrame.merging(_:)` would merge
    /// both: lists appended, hash, watermarks, initialize and snapshot set when present.
    func merging(_ later: ReevaluationTickRecord) -> ReevaluationTickRecord {
        var merged = self
        merged.actions += later.actions
        merged.clientEvents += later.clientEvents
        merged.lifecycleEvents += later.lifecycleEvents
        merged.serverEvents += later.serverEvents
        merged.stateHash = later.stateHash ?? stateHash
        merged.stateSnapshot = later.stateSnapshot ?? stateSnapshot
        merged.sequenceBeforeInputs = later.sequenceBeforeInputs ?? sequenceBeforeInputs
        merged.sequenceBeforeTickHandler = later.sequenceBeforeTickHandler ?? sequenceBeforeTickHandler
        merged.syncOutputs += later.syncOutputs
        merged.syncMarkers += later.syncMarkers
        merged.initialize = later.initialize ?? initialize
        merged.passes += later.passes
        merged.serverInputs += later.serverInputs
        return merged
    }
}

// MARK: - Frame assembly

/// Builds tick frames from tick records with the rules of `ReevaluationRecorder.recordTick(_:)`
/// in 2.6: a record merges into its tick's frame (the last one for that tick), a newer tick opens
/// a frame. The 3.0 reader folds a file's `turn` records through it.
struct ReevaluationFrameAssembler {
    private var frames: [ReevaluationTickFrame] = []
    private var current: ReevaluationTickFrame?

    mutating func add(_ record: ReevaluationTickRecord) {
        if let frame = current, frame.tickId == record.tickId {
            current = frame.merging(record)
        } else if current == nil || record.tickId > current!.tickId {
            if let frame = current { frames.append(frame) }
            current = Self.empty(record.tickId).merging(record)
        } else if let index = frames.lastIndex(where: { $0.tickId == record.tickId }) {
            frames[index] = frames[index].merging(record)
        } else {
            frames.append(Self.empty(record.tickId).merging(record))
        }
    }

    /// The frames sorted by tick.
    func finished() -> [ReevaluationTickFrame] {
        (frames + (current.map { [$0] } ?? [])).sorted { $0.tickId < $1.tickId }
    }

    static func empty(_ tickId: Int64) -> ReevaluationTickFrame {
        ReevaluationTickFrame(tickId: tickId, actions: [], clientEvents: [], lifecycleEvents: [])
    }
}

// MARK: - Reading

/// What a 3.0 file holds, rebuilt into the 2.x model.
struct ReevaluationRecordLogContents: Sendable {
    var metadata: ReevaluationRecordMetadata
    var frames: [ReevaluationTickFrame]
    var completeness: ReevaluationRecordCompleteness
}

/// Errors reading a 3.0 file. A cut file is not an error (it reads as incomplete).
public enum ReevaluationRecordLogError: Error, Equatable, CustomStringConvertible {
    case notALog
    case unsupportedMajor(UInt8)
    /// The record's minor is newer than this build's (from 3.2 on, #387): it may hold keys this
    /// build would ignore, such as 3.2's server inputs, and replay without them.
    case newerMinor(UInt8)
    case missingHeader
    case recordAfterFooter
    case unexpectedRecord(String)

    public var description: String {
        switch self {
        case .notALog: "not a 3.x record (missing SSTR magic)"
        case .unsupportedMajor(let major): "record format major \(major) is not supported by this build"
        case .newerMinor(let minor):
            "record format \(ReevaluationRecordLog.formatVersion.major).\(minor) is newer than this build reads (\(ReevaluationRecordLog.formatVersion.major).\(ReevaluationRecordLog.formatVersion.minor)); replay it with a build at least as new as the one that recorded it"
        case .missingHeader: "record has no header"
        case .recordAfterFooter: "record continues after its footer"
        case .unexpectedRecord(let detail): "unexpected record: \(detail)"
        }
    }
}

enum ReevaluationRecordLogReader {
    static func read(_ bytes: [UInt8]) throws -> ReevaluationRecordLogContents {
        guard ReevaluationRecordLog.hasMagic(bytes) else { throw ReevaluationRecordLogError.notALog }
        guard bytes.count >= ReevaluationRecordLog.preamble.count else {
            throw ReevaluationRecordLogError.missingHeader
        }
        guard bytes[4] == ReevaluationRecordLog.formatVersion.major else {
            throw ReevaluationRecordLogError.unsupportedMajor(bytes[4])
        }
        // A newer minor may hold keys this build ignores, and a replay without them would pass
        // or fail for the wrong reason. Builds before 3.2 don't check this.
        guard bytes[5] <= ReevaluationRecordLog.formatVersion.minor else {
            throw ReevaluationRecordLogError.newerMinor(bytes[5])
        }
        var offset = ReevaluationRecordLog.preamble.count
        var metadata: ReevaluationRecordMetadata?
        var turns: [ReevaluationTickRecord] = []
        var footer: ReevaluationLogRecord?
        var cut = false
        var newestTick: Int64?

        while offset < bytes.count {
            guard footer == nil else { throw ReevaluationRecordLogError.recordAfterFooter }
            guard bytes.count - offset >= 4 else { cut = true; break }
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let start = offset + 4
            guard bytes.count - start >= length else { cut = true; break }
            let record = try CanonicalMessagePack.decode(
                ReevaluationLogRecord.self,
                from: Array(bytes[start..<(start + length)])
            )
            offset = start + length
            switch record.kind {
            case .header:
                guard let recorded = record.metadata else {
                    throw ReevaluationRecordLogError.unexpectedRecord("header without metadata")
                }
                // A later header (metadata set again) replaces the earlier one.
                metadata = recorded
            case .turn:
                guard metadata != nil else { throw ReevaluationRecordLogError.missingHeader }
                guard let tick = record.tickRecord else {
                    throw ReevaluationRecordLogError.unexpectedRecord("turn without tickId")
                }
                turns.append(tick)
                newestTick = max(newestTick ?? tick.tickId, tick.tickId)
            case .footer:
                footer = record
            }
        }
        guard let metadata else { throw ReevaluationRecordLogError.missingHeader }

        let completeness: ReevaluationRecordCompleteness
        if let footer, footer.complete == true {
            completeness = .complete
        } else {
            let reason: String
            if let footer {
                if let pending = footer.pendingSubmissions, pending > 0 {
                    reason = "closed with \(pending) submissions not yet recorded"
                } else {
                    reason = "closed before the end of the run (copy of a live record)"
                }
            } else {
                reason = cut ? "cut inside a record (no footer)" : "no footer (the recording did not close)"
            }
            // The newest tick may have more `turn` records past the cut: leave it out, so it is
            // reported unverified rather than replayed with partial inputs.
            if let newestTick {
                turns = Self.leavingOut(tick: newestTick, from: turns)
            }
            completeness = .incomplete(reason: reason, lastTickUnverified: newestTick)
        }
        var assembler = ReevaluationFrameAssembler()
        for turn in turns { assembler.add(turn) }
        return ReevaluationRecordLogContents(metadata: metadata, frames: assembler.finished(), completeness: completeness)
    }

    /// `turns` without `tick`'s records, and the sync stream cut to its dense prefix
    /// `0..<k`: every entry from the first missing stream index on goes. Entries reach the file
    /// out of stream order (a late seed filed under an older tick can be written before the
    /// pending turn of a newer one), so a cut file can hold an index without the one before it,
    /// whichever tick that one belonged to. The verifier rejects a stream with a gap.
    static func leavingOut(tick: Int64, from turns: [ReevaluationTickRecord]) -> [ReevaluationTickRecord] {
        let kept = turns.filter { $0.tickId != tick }
        let indices = Set(kept.flatMap { $0.syncOutputs.map(\.streamIndex) + $0.syncMarkers.map(\.streamIndex) })
        var prefix: UInt64 = 0
        while indices.contains(prefix) { prefix += 1 }
        return kept.map { turn in
            var turn = turn
            turn.syncOutputs.removeAll { $0.streamIndex >= prefix }
            turn.syncMarkers.removeAll { $0.streamIndex >= prefix }
            return turn
        }
    }
}

// MARK: - Sinks and the writer

/// Where a recorder's bytes go. Called only on the writer's queue.
package protocol ReevaluationRecordSink: AnyObject {
    func append(_ bytes: [UInt8]) throws
    /// Everything appended so far.
    func contents() throws -> [UInt8]
    func close() throws
    /// After `close`: moves the bytes to `path` (replacing a file there), or discards them
    /// when `path` is nil.
    func finish(movingTo path: String?) throws
}

/// A sink writing to a file with `FileHandle.write(contentsOf:)`, which throws on an error
/// (`write(_: Data)` traps, #263).
package final class ReevaluationRecordFileSink: ReevaluationRecordSink {
    package let url: URL
    private var handle: FileHandle?

    package init(url: URL) throws {
        self.url = url
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
    }

    package func append(_ bytes: [UInt8]) throws {
        guard let handle else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        try handle.write(contentsOf: bytes)
    }

    package func contents() throws -> [UInt8] {
        Array(try Data(contentsOf: url))
    }

    package func close() throws {
        let open = handle
        handle = nil
        try open?.close()
    }

    package func finish(movingTo path: String?) throws {
        let fileManager = FileManager.default
        guard let path else {
            try? fileManager.removeItem(at: url)
            return
        }
        let destination = URL(fileURLWithPath: path)
        guard destination.standardizedFileURL != url.standardizedFileURL else { return }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.moveItem(at: url, to: destination)
        } catch {
            // Across volumes: copy, then remove the spool file.
            try fileManager.copyItem(at: url, to: destination)
            try? fileManager.removeItem(at: url)
        }
    }
}

/// Owns a sink on one serial dispatch queue (a GCD thread, not the cooperative pool, so no
/// cooperative thread blocks on file I/O). After the first failed write it drops every later
/// write and reports the error once.
/// A record write that failed; the file was moved, cut at its last complete record.
package struct ReevaluationRecordWriteError: Error, CustomStringConvertible {
    package let underlying: any Error
    package var description: String { "writing the record failed: \(underlying)" }
}

package final class ReevaluationRecordWriter: @unchecked Sendable {
    private let queue: DispatchQueue
    /// Touched only on `queue`.
    private let sink: any ReevaluationRecordSink
    /// The first write error; later appends are dropped. Touched only on `queue`.
    private var failure: (any Error)?
    private let onFailure: @Sendable (any Error) -> Void

    package init(label: String, sink: any ReevaluationRecordSink, onFailure: @escaping @Sendable (any Error) -> Void) {
        self.queue = DispatchQueue(label: label)
        self.sink = sink
        self.onFailure = onFailure
    }

    package func append(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        queue.async { [self] in
            guard failure == nil else { return }
            do {
                try sink.append(bytes)
            } catch {
                failure = error
                onFailure(error)
            }
        }
    }

    /// Everything written so far, after every earlier `append`.
    package func contents() throws -> [UInt8] {
        try queue.sync { try sink.contents() }
    }

    /// Closes the sink after every earlier `append`, then moves its bytes to `path` or discards
    /// them (nil). Throws the move's error, or else the first write error: a write that failed
    /// on the last buffer is reported here, not only through the asynchronous `onFailure`. The
    /// file is moved either way, cut at its last complete record.
    package func finish(movingTo path: String?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                do {
                    try? sink.close()
                    try sink.finish(movingTo: path)
                    if let failure {
                        continuation.resume(throwing: ReevaluationRecordWriteError(underlying: failure))
                    } else {
                        continuation.resume()
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// `finish(movingTo: nil)` without waiting: for a recorder released without a save.
    package func discard() {
        queue.async { [self] in
            try? sink.close()
            try? sink.finish(movingTo: nil)
        }
    }
}
