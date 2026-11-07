import Foundation
import Logging

// MARK: - ReevaluationRecorder Actor

/// Records inputs and outputs for deterministic re-evaluation as a 3.0 log
/// (`ReevaluationRecordLog`), streamed to a spool file while the land runs (#245).
///
/// - Memory: one pending record (the newest tick's calls, merged) and a write buffer, nothing per
///   tick. The buffer goes to the writer's queue at 64 KiB, 1 s after its first record, and at
///   close; the pending record goes with it on the timer, or when a call names a newer tick.
/// - Spool file: `sst-record-<landType>-<landID>-<pid>-<UUID>.sstr`, opened when the metadata is
///   set, in `spoolDirectory`, else `REEVALUATION_SPOOL_DIR`, else the temporary directory.
///   `save(to:)` closes the log and moves the file to its path; a recorder released without a
///   save deletes it. A process that dies leaves it, readable up to its last complete record.
/// - Write errors stop the recording (one warning) and never reach the land (#263).
public actor ReevaluationRecorder {
    /// The buffer size that hands the buffer to the writer.
    static let writeBufferLimit = 64 * 1024
    /// How long after its first record the buffer is handed over at the latest.
    static let flushDelay: Duration = .seconds(1)

    private enum Phase {
        case recording
        case saved(path: String)
        case stopped(reason: String)
    }

    private var metadata: ReevaluationRecordMetadata?
    private let flushInterval: Int64
    private let spoolDirectory: URL?
    private let makeSink: (@Sendable (URL) throws -> any ReevaluationRecordSink)?
    private let logger: Logger

    private var phase: Phase = .recording
    private var writer: ReevaluationRecordWriter?
    private var spoolURL: URL?
    private var stateWriter: ReevaluationRecordWriter?
    private var stateSpoolURL: URL?
    /// Records submitted before the metadata (and so the file) exists.
    private var beforeHeader: [ReevaluationTickRecord] = []
    /// The newest tick's calls, merged, not yet in the buffer.
    private var pending: ReevaluationTickRecord?
    private var buffer: [UInt8] = []
    private var flushScheduled = false
    private var turnCount = 0
    private var maxTickId: Int64 = -1
    private var syncStreamCount = 0
    private var legacyModel: ReevaluationLegacyFrameModel?
    /// Times a write failure was logged (at most once per recorder).
    package private(set) var writeFailureWarnings = 0

    /// Line format of the state JSONL side file.
    private struct RecordedStateLine: Codable {
        let tickId: Int64
        let stateSnapshot: StateSnapshot
    }

    /// Tests: recorders created inside `$recordsLegacyFramesForTesting.withValue(true)` also
    /// build the 2.6 frames (`legacyFramesForTesting()`), from their first call.
    @TaskLocal package static var recordsLegacyFramesForTesting = false

    public init(flushInterval: Int64 = 60, spoolDirectory: URL? = nil, logger: Logger? = nil) {
        self.flushInterval = flushInterval
        self.legacyModel = Self.recordsLegacyFramesForTesting ? ReevaluationLegacyFrameModel() : nil
        self.spoolDirectory = spoolDirectory
        self.makeSink = nil
        self.logger = logger ?? createColoredLogger(
            loggerIdentifier: "com.swiftstatetree.runtime",
            scope: "ReevaluationRecorder"
        )
    }

    /// A recorder writing to sinks `makeSink` creates (tests: a failing sink).
    package init(
        spoolDirectory: URL? = nil,
        logger: Logger? = nil,
        makeSink: @escaping @Sendable (URL) throws -> any ReevaluationRecordSink
    ) {
        self.flushInterval = 60
        self.spoolDirectory = spoolDirectory
        self.makeSink = makeSink
        self.logger = logger ?? createColoredLogger(
            loggerIdentifier: "com.swiftstatetree.runtime",
            scope: "ReevaluationRecorder"
        )
    }

    deinit {
        if case .recording = phase {
            writer?.discard()
            stateWriter?.discard()
        }
    }

    /// Set record metadata (required before saving). The version is always stamped as
    /// `ReevaluationRecordVersion.current`: the hashes this recorder receives are this build's.
    /// The first call opens the spool file and writes the header; a later call writes another
    /// header, which replaces the first on read.
    public func setMetadata(_ metadata: ReevaluationRecordMetadata) {
        let stamped = metadata.stampedWithCurrentVersion()
        self.metadata = stamped
        guard case .recording = phase else { return }
        if writer == nil {
            guard openSpool(for: stamped) else { return }
            enqueue(ReevaluationRecordLog.preamble)
        }
        appendRecord(.header(stamped))
        let early = beforeHeader
        beforeHeader = []
        for record in early {
            submit(record)
        }
    }

    public func getMetadata() -> ReevaluationRecordMetadata? {
        metadata
    }

    /// The spool file this recorder writes to (nil before the metadata is set).
    public func getSpoolPath() -> String? {
        spoolURL?.path
    }

    /// Record actions and client events for a specific tick (legacy path).
    ///
    /// - Parameters:
    ///   - sequenceBeforeInputs: Sequence watermark captured before pending inputs were processed (live ticks only).
    ///   - sequenceBeforeTickHandler: Sequence watermark captured before the tick handler ran (live ticks only).
    public func record(
        tickId: Int64,
        actions: [ReevaluationRecordedAction],
        clientEvents: [ReevaluationRecordedClientEvent],
        lifecycleEvents: [ReevaluationRecordedLifecycleEvent],
        sequenceBeforeInputs: Int64? = nil,
        sequenceBeforeTickHandler: Int64? = nil
    ) {
        legacyModel?.record(
            tickId: tickId, actions: actions, clientEvents: clientEvents, lifecycleEvents: lifecycleEvents,
            sequenceBeforeInputs: sequenceBeforeInputs, sequenceBeforeTickHandler: sequenceBeforeTickHandler
        )
        submit(ReevaluationTickRecord(
            tickId: tickId,
            actions: actions,
            clientEvents: clientEvents,
            lifecycleEvents: lifecycleEvents,
            sequenceBeforeInputs: sequenceBeforeInputs,
            sequenceBeforeTickHandler: sequenceBeforeTickHandler
        ))
    }

    public func recordLifecycleEvent(_ event: ReevaluationRecordedLifecycleEvent) {
        legacyModel?.recordLifecycleEvent(event)
        submit(ReevaluationTickRecord(tickId: event.tickId, lifecycleEvents: [event]))
    }

    /// Set the per-tick state hash (live ground truth).
    public func setStateHash(tickId: Int64, stateHash: String) {
        legacyModel?.setStateHash(tickId: tickId, stateHash: stateHash)
        submit(ReevaluationTickRecord(tickId: tickId, stateHash: stateHash))
    }

    /// Record a full state snapshot for a specific tick (debug-only, enabled via
    /// ENABLE_STATE_SNAPSHOT_RECORDING), streamed to the `-state.jsonl` side file.
    public func recordStateSnapshot(tickId: Int64, stateSnapshot: StateSnapshot) {
        writeStateLine(tickId: tickId, snapshot: stateSnapshot)
    }

    /// Record server events emitted for a specific tick. Appended to the tick's events: a tick
    /// whose outputs are flushed twice (after an action and at the tick) keeps both lists, and
    /// a legacy tickless land keeps every pass's (2.6 kept only the last list).
    public func recordServerEvents(tickId: Int64, events: [ReevaluationRecordedServerEvent]) {
        legacyModel?.recordServerEvents(tickId: tickId, events: events)
        submit(ReevaluationTickRecord(tickId: tickId, serverEvents: events))
    }

    /// Records everything one keeper turn produced for `record.tickId`, in one call.
    ///
    /// Inputs and server events are appended to the tick's; the state hash, snapshot and
    /// sequence watermarks are set when present. A record for an older tick (a late sync entry)
    /// is its own `turn` record, which the reader merges into that tick.
    public func recordTick(_ record: ReevaluationTickRecord) {
        legacyModel?.recordTick(record)
        submit(record)
    }

    /// Kept for callers; the log is flushed by size and time, not by tick count.
    public func flushIfNeeded(currentTick: Int64) async throws {}

    /// Closes the log and moves it to `filePath` (replacing a file there), with the state side
    /// file next to it when snapshots were recorded. Later records are dropped. With
    /// `pendingSubmissions` > 0 (the shutdown drain ran out of time) the footer says the record
    /// is incomplete. Throws when the metadata was never set, or when the recording stopped on a
    /// write error (the file, cut at its last complete record, is moved anyway).
    public func save(to filePath: String, pendingSubmissions: Int = 0) async throws {
        guard metadata != nil, let writer else {
            throw NSError(domain: "ReevaluationRecorder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Re-evaluation record metadata must be set before saving"
            ])
        }
        switch phase {
        case .saved(let path):
            guard path != filePath else { return }
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: filePath) { try fileManager.removeItem(atPath: filePath) }
            try fileManager.copyItem(atPath: path, toPath: filePath)
            return
        case .stopped(let reason):
            phase = .saved(path: filePath)
            try await writer.finish(movingTo: filePath)
            try await stateWriter?.finish(movingTo: Self.statePath(for: filePath))
            throw NSError(domain: "ReevaluationRecorder", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Re-evaluation recording stopped: \(reason); saved up to the last complete record"
            ])
        case .recording:
            break
        }
        writePending()
        appendRecord(footer(complete: pendingSubmissions == 0, pendingSubmissions: pendingSubmissions))
        handOffBuffer()
        phase = .saved(path: filePath)
        try await writer.finish(movingTo: filePath)
        try await stateWriter?.finish(movingTo: Self.statePath(for: filePath))
    }

    /// The record as a file would hold it now, without changing the recorder: the written
    /// bytes, then the buffer and the pending record, then a footer marked incomplete (only in
    /// this copy). After a save, the saved file.
    public func encode() throws -> Data {
        try encodeCopy(complete: false)
    }

    private func encodeCopy(complete: Bool) throws -> Data {
        guard metadata != nil else {
            throw NSError(domain: "ReevaluationRecorder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Re-evaluation record metadata must be set before encoding"
            ])
        }
        if case .saved(let path) = phase {
            return try Data(contentsOf: URL(fileURLWithPath: path))
        }
        handOffBuffer()
        var bytes = try writer?.contents() ?? []
        if case .recording = phase {
            if let pending {
                bytes += try ReevaluationRecordLog.framed(.turn(pending))
            }
            var copyFooter = footer(complete: complete, pendingSubmissions: nil)
            if let pending {
                copyFooter.turnCount = turnCount + 1
                copyFooter.maxTickId = max(maxTickId, pending.tickId)
                copyFooter.syncStreamCount = syncStreamCount + pending.syncOutputs.count + pending.syncMarkers.count
            }
            bytes += try ReevaluationRecordLog.framed(copyFooter)
        }
        return Data(bytes)
    }

    /// Every recorded frame, rebuilt from the log as a reader would (for tests and debugging).
    public func getAllFrames() -> [ReevaluationTickFrame] {
        var assembler = ReevaluationFrameAssembler()
        if metadata != nil, let bytes = try? encode(),
           let records = try? ReevaluationRecordLogReader.records(Array(bytes)) {
            for record in records { assembler.add(record) }
        }
        for record in beforeHeader { assembler.add(record) }
        return assembler.finished()
    }

    // MARK: Testing

    /// Writes the record as `save(to:)` would close it, to `path`, and keeps recording: for
    /// tests that save one live recorder several times.
    package func saveCopyForTesting(to path: String) throws {
        try encodeCopy(complete: true).write(to: URL(fileURLWithPath: path))
    }

    /// The record in the 2.6 JSON shape (`recordMetadata`, `tickFrames`): for tests that edit a
    /// record by hand and read it back through `JSONReevaluationSource`.
    package func encodeJSONViewForTesting() throws -> Data {
        guard let metadata else {
            throw NSError(domain: "ReevaluationRecorder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Re-evaluation record metadata must be set before encoding"
            ])
        }
        struct View: Encodable {
            let recordMetadata: ReevaluationRecordMetadata
            let tickFrames: [ReevaluationTickFrame]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(View(recordMetadata: metadata, tickFrames: getAllFrames()))
    }

    /// Starts building the 2.6 frames from the same calls (the round-trip test compares them
    /// with the log).
    package func recordLegacyFramesForTesting() {
        legacyModel = ReevaluationLegacyFrameModel()
    }

    /// The 2.6 frames of the calls since `recordLegacyFramesForTesting()`.
    package func legacyFramesForTesting() -> [ReevaluationTickFrame] {
        legacyModel?.frames() ?? []
    }

    /// What the recorder holds in memory: buffered bytes and pending or pre-header records.
    package func bufferedStateForTesting() -> (bufferBytes: Int, pendingRecords: Int) {
        (buffer.count, (pending == nil ? 0 : 1) + beforeHeader.count)
    }

    /// Hands the buffer and the pending record to the writer now (tests; the timer does it).
    package func flushForTesting() {
        writePending()
        handOffBuffer()
    }

    // MARK: Internals

    private func submit(_ record: ReevaluationTickRecord) {
        guard case .recording = phase else { return }
        var record = record
        if let snapshot = record.stateSnapshot {
            writeStateLine(tickId: record.tickId, snapshot: snapshot)
            record.stateSnapshot = nil
        }
        guard metadata != nil, writer != nil else {
            beforeHeader.append(record)
            return
        }
        if let current = pending {
            if record.tickId == current.tickId {
                pending = current.merging(record)
            } else if record.tickId > current.tickId {
                appendTurn(current)
                pending = record
            } else {
                appendTurn(record)
            }
        } else {
            pending = record
        }
        scheduleFlush()
    }

    private func writePending() {
        if let current = pending {
            pending = nil
            appendTurn(current)
        }
    }

    private func appendTurn(_ record: ReevaluationTickRecord) {
        turnCount += 1
        maxTickId = max(maxTickId, record.tickId)
        syncStreamCount += record.syncOutputs.count + record.syncMarkers.count
        appendRecord(.turn(record))
    }

    private func appendRecord(_ record: ReevaluationLogRecord) {
        do {
            buffer += try ReevaluationRecordLog.framed(record)
        } catch {
            stop(reason: "encoding a \(record.kind.rawValue) record failed: \(error)")
            return
        }
        if buffer.count >= Self.writeBufferLimit {
            handOffBuffer()
        }
    }

    private func enqueue(_ bytes: [UInt8]) {
        buffer += bytes
    }

    private func handOffBuffer() {
        guard !buffer.isEmpty else { return }
        writer?.append(buffer)
        buffer = []
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [weak self] in
            try? await safeTaskSleep(for: Self.flushDelay)
            await self?.timerFlush()
        }
    }

    private func timerFlush() {
        flushScheduled = false
        guard case .recording = phase else { return }
        writePending()
        handOffBuffer()
    }

    private func footer(complete: Bool, pendingSubmissions: Int?) -> ReevaluationLogRecord {
        var record = ReevaluationLogRecord(kind: .footer)
        record.complete = complete
        record.maxTickId = maxTickId
        record.turnCount = turnCount
        record.syncStreamCount = syncStreamCount
        record.pendingSubmissions = (pendingSubmissions ?? 0) > 0 ? pendingSubmissions : nil
        return record
    }

    private func openSpool(for metadata: ReevaluationRecordMetadata) -> Bool {
        let directory = spoolDirectory
            ?? EnvHelpers.getEnvString(key: EnvKeys.Runtime.reevaluationSpoolDir, defaultValue: "")
                .nonEmpty.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let name = "sst-record-\(Self.fileSafe(metadata.landType))-\(Self.fileSafe(metadata.landID))"
            + "-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8))"
        let url = directory.appendingPathComponent(name + ".sstr")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let sink = try makeSink?(url) ?? ReevaluationRecordFileSink(url: url)
            writer = ReevaluationRecordWriter(label: "swiftstatetree.record.\(name)", sink: sink) { [weak self] error in
                Task { await self?.writeFailed(error) }
            }
            spoolURL = url
            logger.info("Re-evaluation record spooling to \(url.path)")
            return true
        } catch {
            stop(reason: "opening \(url.path) failed: \(error)")
            return false
        }
    }

    private func writeFailed(_ error: any Error) {
        stop(reason: "writing \(spoolURL?.path ?? "the record") failed: \(error)")
    }

    private func stop(reason: String) {
        guard case .recording = phase else { return }
        phase = .stopped(reason: reason)
        buffer = []
        pending = nil
        beforeHeader = []
        writeFailureWarnings += 1
        logger.warning("Re-evaluation recording stopped, the land keeps running: \(reason)")
    }

    private func writeStateLine(tickId: Int64, snapshot: StateSnapshot) {
        guard case .recording = phase else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var line = try? encoder.encode(RecordedStateLine(tickId: tickId, stateSnapshot: snapshot)) else { return }
        line.append(UInt8(ascii: "\n"))
        if stateWriter == nil {
            let directory = spoolURL?.deletingLastPathComponent() ?? spoolDirectory ?? FileManager.default.temporaryDirectory
            let base = spoolURL?.deletingPathExtension().lastPathComponent ?? "sst-record-\(UUID().uuidString.prefix(8))"
            let url = directory.appendingPathComponent(base + "-state.jsonl")
            guard let sink = try? ReevaluationRecordFileSink(url: url) else { return }
            stateSpoolURL = url
            stateWriter = ReevaluationRecordWriter(label: "swiftstatetree.record.state.\(base)", sink: sink) { _ in }
        }
        stateWriter?.append(Array(line))
    }

    /// The state side file of a record at `path`: `x.sstr` / `x.json` → `x-state.jsonl`.
    static func statePath(for path: String) -> String {
        for suffix in [".sstr", ".json"] where path.hasSuffix(suffix) {
            return String(path.dropLast(suffix.count)) + "-state.jsonl"
        }
        return path + "-state.jsonl"
    }

    private static func fileSafe(_ text: String) -> String {
        String(text.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }.prefix(48))
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

extension ReevaluationRecordLogReader {
    /// The `turn` records of `bytes`, in file order, up to the last complete record.
    static func records(_ bytes: [UInt8]) throws -> [ReevaluationTickRecord] {
        var offset = ReevaluationRecordLog.preamble.count
        var result: [ReevaluationTickRecord] = []
        while bytes.count - offset >= 4 {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let start = offset + 4
            guard bytes.count - start >= length else { break }
            let record = try CanonicalMessagePack.decode(ReevaluationLogRecord.self, from: Array(bytes[start..<(start + length)]))
            if let tick = record.tickRecord { result.append(tick) }
            offset = start + length
        }
        return result
    }
}

// MARK: - The 2.6 frame model (tests)

/// How the 2.6 recorder built frames from the same calls, kept for the round-trip test.
struct ReevaluationLegacyFrameModel: Sendable {
    private var frames2: [ReevaluationTickFrame] = []
    private var currentFrame: ReevaluationTickFrame?
    private var currentTickId: Int64 = -1

    private mutating func frame(for tickId: Int64) -> ReevaluationTickFrame {
        if tickId != currentTickId {
            if let frame = currentFrame { frames2.append(frame) }
            currentTickId = tickId
            currentFrame = ReevaluationFrameAssembler.empty(tickId)
        }
        return currentFrame ?? ReevaluationFrameAssembler.empty(tickId)
    }

    mutating func record(
        tickId: Int64,
        actions: [ReevaluationRecordedAction],
        clientEvents: [ReevaluationRecordedClientEvent],
        lifecycleEvents: [ReevaluationRecordedLifecycleEvent],
        sequenceBeforeInputs: Int64?,
        sequenceBeforeTickHandler: Int64?
    ) {
        let frame = frame(for: tickId)
        currentFrame = frame.replacing(
            actions: frame.actions + actions,
            clientEvents: frame.clientEvents + clientEvents,
            lifecycleEvents: frame.lifecycleEvents + lifecycleEvents,
            sequenceBeforeInputs: sequenceBeforeInputs,
            sequenceBeforeTickHandler: sequenceBeforeTickHandler
        )
    }

    mutating func recordLifecycleEvent(_ event: ReevaluationRecordedLifecycleEvent) {
        let frame = frame(for: event.tickId)
        currentFrame = frame.replacing(lifecycleEvents: frame.lifecycleEvents + [event])
    }

    mutating func setStateHash(tickId: Int64, stateHash: String) {
        currentFrame = frame(for: tickId).replacing(stateHash: .some(stateHash))
    }

    mutating func recordServerEvents(tickId: Int64, events: [ReevaluationRecordedServerEvent]) {
        currentFrame = frame(for: tickId).replacing(serverEvents: events)
    }

    mutating func recordTick(_ record: ReevaluationTickRecord) {
        if record.tickId == currentTickId, let frame = currentFrame {
            currentFrame = frame.merging(record)
        } else if record.tickId > currentTickId || currentFrame == nil {
            if let frame = currentFrame { frames2.append(frame) }
            currentTickId = record.tickId
            currentFrame = ReevaluationFrameAssembler.empty(record.tickId).merging(record)
        } else if let index = frames2.lastIndex(where: { $0.tickId == record.tickId }) {
            frames2[index] = frames2[index].merging(record)
        } else {
            frames2.append(ReevaluationFrameAssembler.empty(record.tickId).merging(record))
        }
    }

    func frames() -> [ReevaluationTickFrame] {
        (frames2 + (currentFrame.map { [$0] } ?? [])).sorted { $0.tickId < $1.tickId }
    }
}
