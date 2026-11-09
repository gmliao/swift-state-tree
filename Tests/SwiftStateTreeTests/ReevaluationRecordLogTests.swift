import Foundation
import Testing
@testable import SwiftStateTree

// Record format 3.0 (#245): the streamed log, its reader, truncation, write errors and the
// shutdown drain. Each test spools into its own directory.

private func spoolDirectory(_ name: String = #function) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("record-log-tests-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let fixedMetadata = ReevaluationRecordMetadata(
    landID: "log-test:1",
    landType: "log-test",
    createdAt: Date(timeIntervalSince1970: 1_800_000_000),
    metadata: ["k": "v"],
    rngSeed: 42,
    recordsSyncStream: true
)

private func action(_ sequence: Int64, tick: Int64) -> ReevaluationRecordedAction {
    ReevaluationRecordedAction(
        kind: "action", sequence: sequence, typeIdentifier: "Move",
        payload: AnyCodable(["x": AnyCodable(Int(sequence)), "speed": AnyCodable(1.5)]),
        playerID: "p1", clientID: "c1", sessionID: "s1", resolverOutputs: [:], resolvedAtTick: tick
    )
}

private func event(_ sequence: Int64, tick: Int64) -> ReevaluationRecordedServerEvent {
    ReevaluationRecordedServerEvent(
        kind: "serverEvent", sequence: sequence, tickId: tick, typeIdentifier: "Hit",
        payload: AnyCodable(["damage": AnyCodable(3)]), target: ReevaluationEventTargetRecord.from(.all)
    )
}

private func output(_ streamIndex: UInt64, observed: Int64) -> ReevaluationRecordedSyncOutput {
    ReevaluationRecordedSyncOutput(
        index: Int(streamIndex), turnKind: .tick, observedTickId: observed,
        streamIndex: streamIndex, sequence: Int64(streamIndex), broadcastHash: 0xfeed_0000 + streamIndex
    )
}

/// The calls of a short in-turn run: per-tick records, a late sync entry for an older tick, and
/// a tick with two submissions.
private func recordInTurnRun(_ recorder: ReevaluationRecorder, ticks: Int64 = 6) async {
    await recorder.recordTick(ReevaluationTickRecord(tickId: 0, syncMarkers: [
        ReevaluationRecordedSyncMarker(kind: .seed, playerID: "p1", observedTickId: 0, streamIndex: 0, sequence: 0)
    ]))
    var stream: UInt64 = 1
    for tick in 0..<ticks {
        await recorder.recordTick(ReevaluationTickRecord(
            tickId: tick, actions: [action(tick * 10, tick: tick)], serverEvents: [event(tick * 10 + 1, tick: tick)],
            stateHash: "hash-\(tick)", sequenceBeforeInputs: tick * 10, sequenceBeforeTickHandler: tick * 10 + 1,
            syncOutputs: [output(stream, observed: tick)]
        ))
        stream += 1
        // A second drain in the same tick; at tick 0 it carries a pass (a tickless land's, 3.1)
        // and ends its turn record.
        await recorder.recordTick(ReevaluationTickRecord(
            tickId: tick, actions: [action(tick * 10 + 5, tick: tick)],
            passes: tick == 0 ? [ReevaluationRecordedPass(sequenceBefore: 5, inputs: [5])] : []
        ), endsTurn: tick == 0)
        if tick >= 3 {
            // A late seed, filed under a tick three back.
            await recorder.recordTick(ReevaluationTickRecord(tickId: tick - 3, syncMarkers: [
                ReevaluationRecordedSyncMarker(kind: .seed, playerID: "p\(tick)", observedTickId: tick - 3, streamIndex: stream, sequence: 0)
            ]))
            stream += 1
        }
    }
}

private func json(_ frames: [ReevaluationTickFrame]) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(frames), as: UTF8.self)
}

@Test("A 3.0 record reads back to the frames the 2.6 recorder built from the same calls")
func logRoundTripsToTheLegacyFrames() async throws {
    let dir = try spoolDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let recorder = ReevaluationRecorder(spoolDirectory: dir)
    await recorder.recordLegacyFramesForTesting()
    await recorder.setMetadata(fixedMetadata)
    await recordInTurnRun(recorder)
    let legacy = await recorder.legacyFramesForTesting()
    let path = dir.appendingPathComponent("run.sstr").path
    try await recorder.save(to: path)

    let source = try ReevaluationRecordFile.openSource(filePath: path)
    #expect(source is ReevaluationRecordLogSource)
    #expect(try await source.getRecordCompleteness() == .complete)
    let frames = await (source as! ReevaluationRecordLogSource).getAllFrames()
    #expect(try json(frames) == json(legacy))
    #expect(try await source.getMaxTickId() == 5)
    #expect(try await source.getMetadata().version == "3.1")
    #expect(try await source.getSyncStream().map(\.streamIndex) == Array(0..<10))
    // The late seeds landed in their ticks.
    #expect(frames.first { $0.tickId == 0 }?.syncMarkers.map(\.streamIndex) == [0, 5])
    #expect(frames.first { $0.tickId == 0 }?.passes == [ReevaluationRecordedPass(sequenceBefore: 5, inputs: [5])])
}

@Test("A file cut in any part of a record opens, reports incomplete, and leaves out only its newest tick")
func truncatedFileReadsToTheLastCompleteRecord() async throws {
    let dir = try spoolDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let recorder = ReevaluationRecorder(spoolDirectory: dir)
    await recorder.setMetadata(fixedMetadata)
    await recordInTurnRun(recorder)
    let path = dir.appendingPathComponent("run.sstr").path
    try await recorder.save(to: path)
    let bytes = Array(try Data(contentsOf: URL(fileURLWithPath: path)))

    // Record boundaries, from the length prefixes.
    var boundaries: [Int] = []
    var offset = ReevaluationRecordLog.magic.count + 2
    while offset < bytes.count {
        boundaries.append(offset)
        let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
        offset += 4 + length
    }
    #expect(offset == bytes.count)
    let headerEnd = boundaries[1]
    let footerStart = boundaries.last!

    // Every record after the header is cut at its start, inside its length prefix, just after
    // the prefix, in the middle and one byte before its end: every way a write can stop.
    var cuts: Set<Int> = []
    for (index, start) in boundaries.enumerated() where start >= headerEnd {
        let end = index + 1 < boundaries.count ? boundaries[index + 1] : bytes.count
        cuts.formUnion([start, start + 1, start + 3, start + 4, (start + 4 + end) / 2, end - 1].filter { $0 < end })
    }
    var opened = 0
    for cut in cuts.sorted() {
        let source = try ReevaluationRecordLogSource(bytes: Array(bytes[0..<cut]))
        guard case .incomplete(_, let unverified) = try await source.getRecordCompleteness() else {
            Issue.record("cut at \(cut) of \(bytes.count) reads as complete")
            continue
        }
        let maxTick = try await source.getMaxTickId()
        if let unverified {
            #expect(maxTick < unverified, "cut at \(cut): newest tick \(unverified) is replayed")
        }
        opened += 1
    }
    #expect(opened == cuts.count)
    // Cut before the header is complete: no header.
    #expect(throws: ReevaluationRecordLogError.missingHeader) {
        _ = try ReevaluationRecordLogSource(bytes: Array(bytes[0..<(headerEnd - 1)]))
    }
    // Cut exactly before the footer: every turn is present, the newest tick still unverified.
    let beforeFooter = try ReevaluationRecordLogSource(bytes: Array(bytes[0..<footerStart]))
    #expect(try await beforeFooter.getRecordCompleteness() == .incomplete(reason: "no footer (the recording did not close)", lastTickUnverified: 5))
    #expect(try await beforeFooter.getMaxTickId() == 4)
}

@Test("A cut between two turn records of one tick leaves that tick out instead of replaying it partly")
func cutBetweenTurnsOfOneTick() async throws {
    let dir = try spoolDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let recorder = ReevaluationRecorder(spoolDirectory: dir)
    await recorder.setMetadata(fixedMetadata)
    // A tickless land: every turn is tick 0; the timer-like flush writes each as its own record.
    for sequence in Int64(0)..<4 {
        await recorder.recordTick(ReevaluationTickRecord(tickId: 0, actions: [action(sequence, tick: 0)]))
        await recorder.flushForTesting()
    }
    let path = dir.appendingPathComponent("tickless.sstr").path
    try await recorder.save(to: path)
    let full = Array(try Data(contentsOf: URL(fileURLWithPath: path)))
    let fullSource = try ReevaluationRecordLogSource(bytes: full)
    #expect(try await fullSource.getActions(for: 0).count == 4)

    let footerless = try ReevaluationRecordLogSource(bytes: Array(full.dropLast(20)))
    #expect(try await footerless.getRecordCompleteness() == .incomplete(reason: "cut inside a record (no footer)", lastTickUnverified: 0))
    #expect(try await footerless.getMaxTickId() == -1)
    #expect(try await footerless.getActions(for: 0).isEmpty)
}

/// Accepts `limit` bytes, then fails every write (a full disk).
private final class FailingSink: ReevaluationRecordSink, @unchecked Sendable {
    private let inner: ReevaluationRecordFileSink
    private var remaining: Int
    init(url: URL, limit: Int) throws {
        inner = try ReevaluationRecordFileSink(url: url)
        remaining = limit
    }
    func append(_ bytes: [UInt8]) throws {
        guard bytes.count <= remaining else {
            // Part of the chunk reaches the disk, as with a short write.
            try inner.append(Array(bytes.prefix(remaining)))
            remaining = 0
            throw CocoaError(.fileWriteOutOfSpace)
        }
        remaining -= bytes.count
        try inner.append(bytes)
    }
    func contents() throws -> [UInt8] { try inner.contents() }
    func close() throws { try inner.close() }
    func finish(movingTo path: String?) throws { try inner.finish(movingTo: path) }
}

@Test("A failed write stops the recording with one warning, never crashes, and leaves a readable file (#263)")
func writeFailureStopsRecording() async throws {
    let dir = try spoolDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let recorder = ReevaluationRecorder(spoolDirectory: dir) { url in try FailingSink(url: url, limit: 1500) }
    await recorder.setMetadata(fixedMetadata)
    for tick in Int64(0)..<200 {
        await recorder.recordTick(ReevaluationTickRecord(tickId: tick, actions: [action(tick, tick: tick)], stateHash: "h\(tick)"))
        await recorder.flushForTesting()
    }
    // The failure reaches the recorder from the writer's queue.
    for _ in 0..<200 where await recorder.writeFailureWarnings == 0 {
        await Task.yield()
        _ = try? await recorder.encode()
    }
    #expect(await recorder.writeFailureWarnings == 1)
    // Later records are dropped without another warning.
    await recorder.recordTick(ReevaluationTickRecord(tickId: 500, stateHash: "late"))
    await recorder.flushForTesting()
    #expect(await recorder.writeFailureWarnings == 1)

    let path = dir.appendingPathComponent("failed.sstr").path
    await #expect(throws: (any Error).self) { try await recorder.save(to: path) }
    let source = try ReevaluationRecordFile.openSource(filePath: path)
    guard case .incomplete = try await source.getRecordCompleteness() else {
        Issue.record("a cut record reads as complete")
        return
    }
    let maxTick = try await source.getMaxTickId()
    #expect(maxTick >= 0 && maxTick < 199)
    for tick in 0...maxTick {
        #expect(try await source.getStateHash(for: tick) == "h\(tick)")
    }
}

@Test("The recorder's memory stays bounded over a long recording")
func recorderMemoryIsBounded() async throws {
    let dir = try spoolDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let recorder = ReevaluationRecorder(spoolDirectory: dir)
    await recorder.setMetadata(fixedMetadata)
    var peakBytes = 0
    var peakRecords = 0
    // About 150 B a tick: 2,000 ticks pass the 64 KiB write buffer several times.
    for tick in Int64(0)..<2_000 {
        await recorder.recordTick(ReevaluationTickRecord(
            tickId: tick, actions: [action(tick, tick: tick)], serverEvents: [event(tick, tick: tick)],
            stateHash: "h\(tick)", syncOutputs: [output(UInt64(tick), observed: tick)]
        ))
        let held = await recorder.bufferedStateForTesting()
        peakBytes = max(peakBytes, held.bufferBytes)
        peakRecords = max(peakRecords, held.pendingRecords)
    }
    #expect(peakBytes < ReevaluationRecorder.writeBufferLimit + 4096)
    #expect(peakRecords <= 1)
    let path = dir.appendingPathComponent("long.sstr").path
    try await recorder.save(to: path)
    #expect(try await ReevaluationRecordFile.openSource(filePath: path).getMaxTickId() == 1_999)
    let fileBytes = try Data(contentsOf: URL(fileURLWithPath: path)).count
    #expect(fileBytes > 3 * ReevaluationRecorder.writeBufferLimit, "\(fileBytes) B: the run must pass the buffer limit several times")
}

@Test("Recording the same calls twice gives byte-identical files")
func recordingIsDeterministic() async throws {
    let dir = try spoolDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    var files: [Data] = []
    for run in 0..<2 {
        let recorder = ReevaluationRecorder(spoolDirectory: dir)
        await recorder.setMetadata(fixedMetadata)
        await recordInTurnRun(recorder)
        let path = dir.appendingPathComponent("run\(run).sstr").path
        try await recorder.save(to: path)
        files.append(try Data(contentsOf: URL(fileURLWithPath: path)))
    }
    #expect(files[0] == files[1])
}

@Test("encode() mid-run returns a copy marked incomplete; the live file gets no footer")
func encodeMidRunIsAnIncompleteCopy() async throws {
    let dir = try spoolDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let recorder = ReevaluationRecorder(spoolDirectory: dir)
    await recorder.setMetadata(fixedMetadata)
    await recordInTurnRun(recorder)
    let copy = try await recorder.encode()
    let source = try ReevaluationRecordFile.openSource(data: copy)
    #expect(try await source.getRecordCompleteness() == .incomplete(reason: "closed before the end of the run (copy of a live record)", lastTickUnverified: 5))
    #expect(try await source.getMaxTickId() == 4)

    let spool = try #require(await recorder.getSpoolPath())
    let live = Array(try Data(contentsOf: URL(fileURLWithPath: spool)))
    let liveSource = try ReevaluationRecordLogSource(bytes: live)
    guard case .incomplete(let reason, _) = try await liveSource.getRecordCompleteness() else {
        Issue.record("the live file has a footer")
        return
    }
    #expect(reason == "no footer (the recording did not close)")
}

@Test("Server events of one tick flushed twice keep both lists (2.6 kept the second)")
func serverEventsOfOneTickAppend() async throws {
    let dir = try spoolDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let recorder = ReevaluationRecorder(spoolDirectory: dir)
    await recorder.recordLegacyFramesForTesting()
    await recorder.setMetadata(fixedMetadata)
    await recorder.recordServerEvents(tickId: 3, events: [event(1, tick: 3)])
    await recorder.recordServerEvents(tickId: 3, events: [event(2, tick: 3)])
    await recorder.setStateHash(tickId: 3, stateHash: "h3")
    let path = dir.appendingPathComponent("events.sstr").path
    try await recorder.save(to: path)
    let source = try ReevaluationRecordFile.openSource(filePath: path)
    #expect(try await source.getServerEvents(for: 3).map(\.sequence) == [1, 2])
    #expect(await recorder.legacyFramesForTesting().first?.serverEvents.map(\.sequence) == [2])
}

@Test("A recorder released without a save deletes its spool file; a saved one moves it")
func spoolFileLifecycle() async throws {
    let dir = try spoolDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    var spool: String?
    do {
        let recorder = ReevaluationRecorder(spoolDirectory: dir)
        await recorder.setMetadata(fixedMetadata)
        await recordInTurnRun(recorder)
        await recorder.flushForTesting()
        spool = await recorder.getSpoolPath()
        _ = try await recorder.encode()  // the bytes reached the file
        #expect(FileManager.default.fileExists(atPath: spool!))
        #expect(spool!.contains("sst-record-log-test-log-test_1-"))
    }
    // The delete runs on the writer's queue after the recorder is released.
    var gone = false
    for _ in 0..<500 {
        if !FileManager.default.fileExists(atPath: spool!) { gone = true; break }
        try await safeTaskSleep(for: .milliseconds(10))
    }
    #expect(gone)

    let saved = ReevaluationRecorder(spoolDirectory: dir)
    await saved.setMetadata(fixedMetadata)
    let savedSpool = try #require(await saved.getSpoolPath())
    let path = dir.appendingPathComponent("kept.sstr").path
    try await saved.save(to: path)
    #expect(!FileManager.default.fileExists(atPath: savedSpool))
    #expect(FileManager.default.fileExists(atPath: path))
}

@Test("Records submitted before the metadata are written after the header")
func recordsBeforeMetadataAreKept() async throws {
    let dir = try spoolDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let recorder = ReevaluationRecorder(spoolDirectory: dir)
    await recorder.recordTick(ReevaluationTickRecord(tickId: 0))
    await recorder.recordTick(ReevaluationTickRecord(tickId: 0, actions: [action(1, tick: 0)]))
    #expect(await recorder.getAllFrames().first?.actions.count == 1)
    await recorder.setMetadata(fixedMetadata)
    let path = dir.appendingPathComponent("early.sstr").path
    try await recorder.save(to: path)
    #expect(try await ReevaluationRecordFile.openSource(filePath: path).getActions(for: 0).count == 1)
}

/// Holds a submission until opened.
private actor DrainGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private(set) var applied = 0
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
    func apply() { applied += 1 }
}

@Test("The shutdown drain waits for submissions, and on its deadline reports the ones still pending")
func submissionDrainHasADeadline() async throws {
    let tracker = ReevaluationSubmissionTracker()
    let gate = DrainGate()
    tracker.submit { await gate.apply() }
    tracker.submit { await gate.wait(); await gate.apply() }
    // The held submission can't finish: the drain returns on its deadline.
    #expect(await tracker.drain(within: .milliseconds(50)) == 1)
    #expect(await gate.applied == 1)
    await gate.open()
    #expect(await tracker.drain(within: .seconds(30)) == 0)
    #expect(await gate.applied == 2)

    let dir = try spoolDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let recorder = ReevaluationRecorder(spoolDirectory: dir)
    await recorder.setMetadata(fixedMetadata)
    await recordInTurnRun(recorder)
    let path = dir.appendingPathComponent("drained.sstr").path
    try await recorder.save(to: path, pendingSubmissions: 2)
    let source = try ReevaluationRecordFile.openSource(filePath: path)
    #expect(try await source.getRecordCompleteness() == .incomplete(reason: "closed with 2 submissions not yet recorded", lastTickUnverified: 5))
}

@Test("Version rules for 3.x: 2.5+ and 3.x read; a named requirement compares majors")
func recordVersionRulesForThree() {
    #expect(ReevaluationRecordVersion.current == "3.1")
    #expect(ReevaluationRecordVersion.isReadable(recorded: "3.0"))
    #expect(ReevaluationRecordVersion.isReadable(recorded: "3.1"))
    #expect(ReevaluationRecordVersion.isCompatible(recorded: "3.0", required: "3.1"))
    #expect(ReevaluationRecordVersion.isReadable(recorded: "3.7"))
    #expect(ReevaluationRecordVersion.isReadable(recorded: "2.6"))
    #expect(ReevaluationRecordVersion.isReadable(recorded: "2.5"))
    #expect(!ReevaluationRecordVersion.isReadable(recorded: "2.4"))
    #expect(!ReevaluationRecordVersion.isReadable(recorded: "4.0"))
    #expect(!ReevaluationRecordVersion.isReadable(recorded: nil))
    #expect(ReevaluationRecordVersion.isCompatible(recorded: "3.0", required: "3.0"))
    #expect(!ReevaluationRecordVersion.isCompatible(recorded: "2.6", required: "3.0"))
    #expect(ReevaluationRecordVersion.isCompatible(recorded: "2.5", required: "2.6"))
    #expect(ReevaluationRecordVersion.unsupportedReason(recorded: "2.4") != nil)
    #expect(ReevaluationRecordVersion.unsupportedReason(recorded: "3.0") == nil)
    #expect(ReevaluationRecordVersion.minimumSupported == "2.5")
    #expect(ReevaluationRecordVersion.hashDefinition(recorded: "3.0") == .fullState)
    #expect(ReevaluationRecordVersion.hashDefinition(recorded: "2.3") == .broadcastView)
}

// MARK: - Closing (review of #266)

/// A payload with a `Date` past year 9999: encoding a turn with it throws (`dateOutOfRange`).
private func unencodableAction(tick: Int64) -> ReevaluationRecordedAction {
    ReevaluationRecordedAction(
        kind: "action", sequence: 999, typeIdentifier: "Late",
        payload: AnyCodable(["at": Date(timeIntervalSince1970: 1e13)]),
        playerID: "p1", clientID: "c1", sessionID: "s1", resolverOutputs: [:], resolvedAtTick: tick
    )
}

@Test("A turn that fails to encode inside save never gets a complete footer; the encoded records are kept")
func encodeFailureInSaveIsIncomplete() async throws {
    let dir = try spoolDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let recorder = ReevaluationRecorder(spoolDirectory: dir)
    await recorder.setMetadata(fixedMetadata)
    // Ticks 0...3 stay in the buffer (no flush); tick 4, pending, can't be encoded.
    for tick in Int64(0)..<4 {
        await recorder.recordTick(ReevaluationTickRecord(tickId: tick, actions: [action(tick, tick: tick)], stateHash: "h\(tick)"))
    }
    await recorder.recordTick(ReevaluationTickRecord(tickId: 4, actions: [unencodableAction(tick: 4)], stateHash: "h4"))

    let path = dir.appendingPathComponent("unencodable.sstr").path
    await #expect(throws: (any Error).self) { try await recorder.save(to: path) }
    #expect(await recorder.writeFailureWarnings == 1)
    let source = try ReevaluationRecordFile.openSource(filePath: path)
    guard case .incomplete = try await source.getRecordCompleteness() else {
        Issue.record("a record missing a turn reads as complete")
        return
    }
    // The header and the buffered ticks reached the file; the reader leaves out the newest.
    #expect(try await source.getMetadata().landID == fixedMetadata.landID)
    #expect(try await source.getMaxTickId() == 2)
    #expect(try await source.getStateHash(for: 2) == "h2")
    // Every later save throws too.
    await #expect(throws: (any Error).self) { try await recorder.save(to: path) }
}

/// Fails its `failingCall`-th append (1-based) and every later one.
private final class FailOnAppendSink: ReevaluationRecordSink, @unchecked Sendable {
    private let inner: ReevaluationRecordFileSink
    private let failingCall: Int
    private var calls = 0
    init(url: URL, failingCall: Int) throws {
        inner = try ReevaluationRecordFileSink(url: url)
        self.failingCall = failingCall
    }
    func append(_ bytes: [UInt8]) throws {
        calls += 1
        guard calls < failingCall else { throw CocoaError(.fileWriteOutOfSpace) }
        try inner.append(bytes)
    }
    func contents() throws -> [UInt8] { try inner.contents() }
    func close() throws { try inner.close() }
    func finish(movingTo path: String?) throws { try inner.finish(movingTo: path) }
}

@Test("A write failure on the final buffer and footer makes save throw, and the file reads incomplete")
func lateWriteFailureFailsSave() async throws {
    let dir = try spoolDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let recorder = ReevaluationRecorder(spoolDirectory: dir) { url in try FailOnAppendSink(url: url, failingCall: 2) }
    await recorder.setMetadata(fixedMetadata)
    await recorder.recordTick(ReevaluationTickRecord(tickId: 0, actions: [action(0, tick: 0)], stateHash: "h0"))
    await recorder.flushForTesting()  // append 1: header and tick 0
    await recorder.recordTick(ReevaluationTickRecord(tickId: 1, actions: [action(1, tick: 1)], stateHash: "h1"))

    let path = dir.appendingPathComponent("late-failure.sstr").path
    // Append 2 (tick 1 and the footer) fails on the writer's queue, after save's last check.
    await #expect(throws: (any Error).self) { try await recorder.save(to: path) }
    let source = try ReevaluationRecordFile.openSource(filePath: path)
    guard case .incomplete = try await source.getRecordCompleteness() else {
        Issue.record("a record whose footer was never written reads as complete")
        return
    }
    await #expect(throws: (any Error).self) { try await recorder.save(to: path) }
}

@Test("A save whose move fails is not saved: a retry to the same path throws, one to another path saves the record")
func failedMoveIsRetryable() async throws {
    let dir = try spoolDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let recorder = ReevaluationRecorder(spoolDirectory: dir)
    await recorder.setMetadata(fixedMetadata)
    await recorder.recordTick(ReevaluationTickRecord(tickId: 0, stateHash: "h0"))
    let unreachable = dir.appendingPathComponent("missing-dir/sub/record.sstr").path
    await #expect(throws: (any Error).self) { try await recorder.save(to: unreachable) }
    await #expect(throws: (any Error).self) { try await recorder.save(to: unreachable) }
    #expect(!FileManager.default.fileExists(atPath: unreachable))
    // The log stayed at the spool path, closed with its footer: a retry elsewhere saves it.
    let path = dir.appendingPathComponent("retried.sstr").path
    try await recorder.save(to: path)
    let source = try ReevaluationRecordFile.openSource(filePath: path)
    #expect(try await source.getRecordCompleteness() == .complete)
    #expect(try await source.getStateHash(for: 0) == "h0")
}

@Test("A cut file with a late seed after its newest tick's output keeps a gapless sync stream")
func truncationKeepsTheSyncStreamGapless() async throws {
    let dir = try spoolDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let recorder = ReevaluationRecorder(spoolDirectory: dir)
    await recorder.setMetadata(fixedMetadata)
    // Tick 5's output, then a late seed filed under tick 2 with the next stream index.
    await recordInTurnRun(recorder)
    let copy = try await recorder.encode()
    let source = try ReevaluationRecordFile.openSource(data: copy)
    #expect(try await source.getRecordCompleteness() == .incomplete(reason: "closed before the end of the run (copy of a live record)", lastTickUnverified: 5))
    let stream = try await source.getSyncStream().map(\.streamIndex)
    #expect(stream == Array(0..<UInt64(stream.count)), "a gap the verifier rejects: \(stream)")
    // Everything from tick 5's first entry on is left out, the late seed of tick 2 included.
    let completePath = dir.appendingPathComponent("complete.sstr").path
    try await recorder.saveCopyForTesting(to: completePath)
    let complete = try ReevaluationRecordFile.openSource(filePath: completePath)
    let full = try await complete.getSyncStream().map(\.streamIndex)
    #expect(stream.count < full.count)
    #expect(Array(full.prefix(stream.count)) == stream)
}

@Test("A cut file keeps only the dense prefix of the sync stream, also when the left-out tick has no entries")
func truncationKeepsTheDensePrefix() async throws {
    // Written order of a live run cut mid-way: tick 2 (the newest written, no sync entries);
    // tick 3's output (index 3) still pending in memory, never written; a late seed filed under
    // tick 1 with index 4, written straight from the submission.
    var header = ReevaluationLogRecord(kind: .header)
    header.metadata = fixedMetadata.stampedWithCurrentVersion()
    var bytes = ReevaluationRecordLog.preamble
    bytes += try ReevaluationRecordLog.framed(header)
    for turn in [
        ReevaluationTickRecord(tickId: 0, stateHash: "h0", syncOutputs: [output(1, observed: 0)], syncMarkers: [
            ReevaluationRecordedSyncMarker(kind: .seed, playerID: "p1", observedTickId: 0, streamIndex: 0, sequence: 0)
        ]),
        ReevaluationTickRecord(tickId: 1, stateHash: "h1", syncOutputs: [output(2, observed: 1)]),
        ReevaluationTickRecord(tickId: 2, stateHash: "h2"),
        ReevaluationTickRecord(tickId: 1, syncMarkers: [
            ReevaluationRecordedSyncMarker(kind: .seed, playerID: "p2", observedTickId: 1, streamIndex: 4, sequence: 0)
        ]),
    ] {
        bytes += try ReevaluationRecordLog.framed(.turn(turn))
    }
    let source = try ReevaluationRecordLogSource(bytes: bytes)
    #expect(try await source.getRecordCompleteness() == .incomplete(reason: "no footer (the recording did not close)", lastTickUnverified: 2))
    #expect(try await source.getSyncStream().map(\.streamIndex) == [0, 1, 2])
    #expect(try await source.getMaxTickId() == 1)
}
