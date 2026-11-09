import Foundation
import Testing
@testable import SwiftStateTree

// #327: the recorder's flush timer only hands closed records to the writer. A tick's pending
// record closes when a newer tick arrives (or at save); a tickless land's at each keeper turn
// end. The timer is forced to fire after every call (`forceTimerFlushAfterEverySubmitForTesting`)
// instead of waiting for it.

private let turnMetadata = ReevaluationRecordMetadata(
    landID: "turn-boundary:1",
    landType: "turn-boundary",
    createdAt: Date(timeIntervalSince1970: 1_800_000_000),
    metadata: [:],
    rngSeed: 7,
    recordsSyncStream: true
)

private func turnAction(_ sequence: Int64, tick: Int64) -> ReevaluationRecordedAction {
    ReevaluationRecordedAction(
        kind: "action", sequence: sequence, typeIdentifier: "Move",
        payload: AnyCodable(["x": AnyCodable(Int(sequence))]),
        playerID: "p1", clientID: "c1", sessionID: "s1", resolverOutputs: [:], resolvedAtTick: tick
    )
}

private func turnEvent(_ sequence: Int64, tick: Int64) -> ReevaluationRecordedServerEvent {
    ReevaluationRecordedServerEvent(
        kind: "serverEvent", sequence: sequence, tickId: tick, typeIdentifier: "Hit",
        payload: AnyCodable(["damage": AnyCodable(1)]), target: ReevaluationEventTargetRecord.from(.all)
    )
}

private func turnOutput(_ streamIndex: UInt64, observed: Int64) -> ReevaluationRecordedSyncOutput {
    ReevaluationRecordedSyncOutput(
        index: 0, turnKind: .tick, observedTickId: observed,
        streamIndex: streamIndex, sequence: Int64(streamIndex), broadcastHash: 0xbeef_0000 + streamIndex
    )
}

private func makeRecorder(forceTimer: Bool) async throws -> (ReevaluationRecorder, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("turn-boundary-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let recorder = ReevaluationRecorder(spoolDirectory: dir)
    if forceTimer { await recorder.forceTimerFlushAfterEverySubmitForTesting() }
    await recorder.setMetadata(turnMetadata)
    return (recorder, dir)
}

private func saved(_ recorder: ReevaluationRecorder, in dir: URL) async throws -> [UInt8] {
    let path = dir.appendingPathComponent("record.sstr").path
    try await recorder.save(to: path)
    defer { try? FileManager.default.removeItem(at: dir) }
    return Array(try Data(contentsOf: URL(fileURLWithPath: path)))
}

/// A legacy tick's calls: inputs, the state hash, the server events and the watermark frame.
private func playTickLand(_ recorder: ReevaluationRecorder, ticks: Int64) async {
    for tick in 0..<ticks {
        await recorder.record(tickId: tick, actions: [turnAction(tick * 10, tick: tick)], clientEvents: [], lifecycleEvents: [])
        await recorder.setStateHash(tickId: tick, stateHash: "h\(tick)")
        await recorder.recordServerEvents(tickId: tick, events: [turnEvent(tick * 10 + 1, tick: tick)])
        await recorder.recordTick(ReevaluationTickRecord(tickId: tick, syncOutputs: [turnOutput(UInt64(tick), observed: tick)]))
        await recorder.record(
            tickId: tick, actions: [], clientEvents: [], lifecycleEvents: [],
            sequenceBeforeInputs: tick * 10, sequenceBeforeTickHandler: tick * 10 + 1
        )
    }
}

/// A tickless land's turns, all tick 0: inputs, sync outputs, server events, then the turn end
/// (on the last call, or as its own `endTurn`).
private func playTicklessLand(_ recorder: ReevaluationRecorder, turns: Int64, peakPending: inout Int) async {
    for turn in 0..<turns {
        await recorder.recordTick(ReevaluationTickRecord(tickId: 0, actions: [turnAction(turn * 10, tick: 0)]))
        peakPending = max(peakPending, await recorder.bufferedStateForTesting().pendingRecords)
        await recorder.recordTick(ReevaluationTickRecord(tickId: 0, syncOutputs: [turnOutput(UInt64(turn), observed: 0)]))
        peakPending = max(peakPending, await recorder.bufferedStateForTesting().pendingRecords)
        if turn.isMultiple(of: 2) {
            await recorder.recordTick(ReevaluationTickRecord(tickId: 0, serverEvents: [turnEvent(turn * 10 + 1, tick: 0)]), endsTurn: true)
        } else {
            await recorder.recordServerEvents(tickId: 0, events: [turnEvent(turn * 10 + 1, tick: 0)])
            await recorder.endTurn()
        }
    }
}

@Test("A tick land's record is the same bytes with the timer firing between any two calls, one turn per tick")
func tickLandBytesIgnoreTheTimer() async throws {
    var files: [[UInt8]] = []
    for force in [false, true] {
        let (recorder, dir) = try await makeRecorder(forceTimer: force)
        await playTickLand(recorder, ticks: 12)
        files.append(try await saved(recorder, in: dir))
    }
    #expect(files[0] == files[1])
    #expect(try ReevaluationRecordLogReader.records(files[1]).map(\.tickId) == Array(0..<12))
}

@Test("A tickless land's record is the same bytes with the timer firing between any two calls, one turn per keeper turn")
func ticklessLandBytesIgnoreTheTimer() async throws {
    var files: [[UInt8]] = []
    for force in [false, true] {
        let (recorder, dir) = try await makeRecorder(forceTimer: force)
        var peakPending = 0
        await playTicklessLand(recorder, turns: 9, peakPending: &peakPending)
        #expect(peakPending <= 1)
        #expect(await recorder.backstopClosesForTesting == 0)
        files.append(try await saved(recorder, in: dir))
    }
    #expect(files[0] == files[1])
    let turns = try ReevaluationRecordLogReader.records(files[1])
    #expect(turns.count == 9)
    #expect(turns.allSatisfy { $0.tickId == 0 && $0.actions.count == 1 && $0.syncOutputs.count == 1 && $0.serverEvents.count == 1 })
}

@Test("The timer firing inside a turn leaves the turn open")
func timerKeepsTheOpenTurn() async throws {
    let (recorder, dir) = try await makeRecorder(forceTimer: false)
    await recorder.recordTick(ReevaluationTickRecord(tickId: 0, actions: [turnAction(0, tick: 0)]))
    await recorder.timerFlushForTesting()
    #expect(await recorder.bufferedStateForTesting().pendingRecords == 1)
    await recorder.recordTick(ReevaluationTickRecord(tickId: 0, actions: [turnAction(1, tick: 0)]), endsTurn: true)
    #expect(await recorder.bufferedStateForTesting().pendingRecords == 0)
    let turns = try ReevaluationRecordLogReader.records(try await saved(recorder, in: dir))
    #expect(turns.map(\.actions.count) == [2])
}

@Test("A turn end before the header is kept for the records replayed after it")
func turnEndBeforeTheHeader() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("turn-boundary-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let recorder = ReevaluationRecorder(spoolDirectory: dir)
    await recorder.recordTick(ReevaluationTickRecord(tickId: 0, actions: [turnAction(0, tick: 0)]))
    await recorder.endTurn()
    await recorder.recordTick(ReevaluationTickRecord(tickId: 0, actions: [turnAction(1, tick: 0)]), endsTurn: true)
    await recorder.setMetadata(turnMetadata)
    let turns = try ReevaluationRecordLogReader.records(try await saved(recorder, in: dir))
    #expect(turns.map(\.actions.count) == [1, 1])
}

@Test("Without a turn end the backstop closes a turn after a fixed number of calls, once warned")
func backstopClosesAnUnsignalledTurn() async throws {
    let (recorder, dir) = try await makeRecorder(forceTimer: true)
    let calls = ReevaluationRecorder.backstopMergedCalls + 1
    for n in 0..<calls {
        await recorder.setStateHash(tickId: 0, stateHash: "h\(n)")
    }
    #expect(await recorder.backstopClosesForTesting == 1)
    let turns = try ReevaluationRecordLogReader.records(try await saved(recorder, in: dir))
    #expect(turns.map(\.stateHash) == ["h\(calls - 2)", "h\(calls - 1)"])
}
