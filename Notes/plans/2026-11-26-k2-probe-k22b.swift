// P-K2-2b (K2 plan §4.5): the sync stream's order around a superseding join's clear, on main
// before K2-2. Not for commit: K2-2's package admission path must record the same order.
// It is appended to Tests/SwiftStateTreeTransportTests/SyncStreamLeaveReplayTests.swift, whose
// private `recordLeaveCase` it calls. It ran at #896's head c0ae1b62 (K1b-5b flows 3+4, on #895;
// main has no OnJoin variant of that helper), macOS, debug, and printed:
//
//   tick=false/onJoin=false violations=0 failure=nil p2Joins=0
//   tick=false/onJoin=false frame 0: lifecycle=["leave(p2)@6"]
//   tick=false/onJoin=false stream 0: output syncOnly observedTick=Optional(-1) sequence=0
//   tick=false/onJoin=false stream 1: marker seed player=p1 observedTick=Optional(-1)
//   tick=false/onJoin=false stream 2: output syncOnly observedTick=Optional(-1) sequence=0
//   tick=false/onJoin=false stream 3: marker seed player=p2 observedTick=Optional(-1)
//   tick=false/onJoin=false stream 4: output tick observedTick=Optional(-1) sequence=3
//   tick=false/onJoin=false stream 5: output tick observedTick=Optional(-1) sequence=6
//   tick=false/onJoin=false stream 6: output tick observedTick=Optional(-1) sequence=8
//   tick=false/onJoin=false stream 7: marker clear player=p2 observedTick=nil
//   tick=false/onJoin=false stream 8: output syncOnly observedTick=Optional(-1) sequence=8
//   tick=false/onJoin=false stream 9: marker seed player=p2 observedTick=Optional(-1)
//   tick=false/onJoin=false stream 10: output tick observedTick=Optional(-1) sequence=11
//   tick=false/onJoin=false stream 11: output tick observedTick=Optional(-1) sequence=14
//   tick=false/onJoin=true violations=0 failure=nil p2Joins=2
//   tick=false/onJoin=true frame 0: lifecycle=["join(p1)@0", "join(p2)@1", "leave(p2)@8", "join(p2)@10"]
//   tick=false/onJoin=true stream 0: output tick observedTick=Optional(-1) sequence=1
//   tick=false/onJoin=true stream 1: marker seed player=p1 observedTick=Optional(-1)
//   tick=false/onJoin=true stream 2: output tick observedTick=Optional(-1) sequence=2
//   tick=false/onJoin=true stream 3: marker seed player=p2 observedTick=Optional(-1)
//   tick=false/onJoin=true stream 4: output tick observedTick=Optional(-1) sequence=5
//   tick=false/onJoin=true stream 5: output tick observedTick=Optional(-1) sequence=8
//   tick=false/onJoin=true stream 6: output tick observedTick=Optional(-1) sequence=10
//   tick=false/onJoin=true stream 7: marker clear player=p2 observedTick=nil
//   tick=false/onJoin=true stream 8: output tick observedTick=Optional(-1) sequence=11
//   tick=false/onJoin=true stream 9: marker seed player=p2 observedTick=Optional(-1)
//   tick=false/onJoin=true stream 10: output tick observedTick=Optional(-1) sequence=14
//   tick=false/onJoin=true stream 11: output tick observedTick=Optional(-1) sequence=17
//   tick=true/onJoin=false violations=0 failure=nil p2Joins=0
//   tick=true/onJoin=false frame 0: lifecycle=[]
//   tick=true/onJoin=false frame 1: lifecycle=[]
//   tick=true/onJoin=false frame 2: lifecycle=["leave(p2)@8"]
//   tick=true/onJoin=false frame 3: lifecycle=[]
//   tick=true/onJoin=false stream 0: marker seed player=p1 observedTick=Optional(-1)
//   tick=true/onJoin=false stream 1: marker seed player=p2 observedTick=Optional(-1)
//   tick=true/onJoin=false stream 2: output tick observedTick=Optional(0) sequence=4
//   tick=true/onJoin=false stream 3: output tick observedTick=Optional(1) sequence=8
//   tick=true/onJoin=false stream 4: marker clear player=p2 observedTick=nil
//   tick=true/onJoin=false stream 5: marker seed player=p2 observedTick=Optional(1)
//   tick=true/onJoin=false stream 6: output tick observedTick=Optional(2) sequence=14
//   tick=true/onJoin=false stream 7: output tick observedTick=Optional(3) sequence=18
//   tick=true/onJoin=true violations=0 failure=nil p2Joins=2
//   tick=true/onJoin=true frame 0: lifecycle=["join(p1)@0", "join(p2)@1"]
//   tick=true/onJoin=true frame 1: lifecycle=[]
//   tick=true/onJoin=true frame 2: lifecycle=["leave(p2)@10", "join(p2)@11"]
//   tick=true/onJoin=true frame 3: lifecycle=[]
//   tick=true/onJoin=true stream 0: marker seed player=p1 observedTick=Optional(-1)
//   tick=true/onJoin=true stream 1: marker seed player=p2 observedTick=Optional(-1)
//   tick=true/onJoin=true stream 2: output tick observedTick=Optional(0) sequence=6
//   tick=true/onJoin=true stream 3: output tick observedTick=Optional(1) sequence=10
//   tick=true/onJoin=true stream 4: marker clear player=p2 observedTick=nil
//   tick=true/onJoin=true stream 5: marker seed player=p2 observedTick=Optional(1)
//   tick=true/onJoin=true stream 6: output tick observedTick=Optional(2) sequence=17
//   tick=true/onJoin=true stream 7: output tick observedTick=Optional(3) sequence=21
@Suite("PROBE K2-2b")
struct ProbeK22BTests {
    @Test("PROBE K2-2b: the stream around a superseding join's clear", arguments: [true, false], [true, false])
    func probe(tick: Bool, onJoin: Bool) async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("probe-k22b-\(UUID().uuidString).sstr").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let record = try await recordLeaveCase(.otherSessionRemains, tick: tick, path: path, onJoin: onJoin)
        print("probe-k22b tick=\(tick)/onJoin=\(onJoin) violations=\(record.reentryViolations) failure=\(String(describing: record.failure)) p2Joins=\(record.p2JoinInputs)")
        let source = try ReevaluationRecordFile.openSource(filePath: path)
        let maxTick = try await source.getMaxTickId()
        if maxTick >= 0 {
            for tickId in 0...maxTick {
                let lifecycle = try await source.getLifecycleEvents(for: tickId).map { "\($0.kind)(\($0.playerID ?? "-"))@\($0.sequence)" }
                print("probe-k22b tick=\(tick)/onJoin=\(onJoin) frame \(tickId): lifecycle=\(lifecycle)")
            }
        }
        for entry in try await source.getSyncStream() {
            switch entry {
            case .marker(let m):
                print("probe-k22b tick=\(tick)/onJoin=\(onJoin) stream \(m.streamIndex): marker \(m.kind) player=\(m.playerID ?? "-") observedTick=\(String(describing: m.observedTickId))")
            case .output(let o):
                print("probe-k22b tick=\(tick)/onJoin=\(onJoin) stream \(o.streamIndex): output \(o.turnKind) observedTick=\(String(describing: o.observedTickId)) sequence=\(o.sequence)")
            }
        }
    }
}
