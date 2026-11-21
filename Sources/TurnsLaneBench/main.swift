// The lane's cost per operation on an empty lane (Notes/plans/2026-11-21-turn-core-post-lane.md
// §3.8): an emit and a call on a machine that takes lane reports (side `lane`), against the same
// machine with `LaneReport == Never` (side `laneoff`). Recorded, not gated. Release builds only.
//
//   TurnsLaneBench [emit|call|all] [lane|laneoff|both] [iterations]
//
// One cell and one side per run is what a normal counter (`perf stat`) wraps. A separate target
// from TurnsBench: in one binary, LLVM merges identical specializations of the two machines with
// TurnsBench's, and the merged thunks move its gated cells.

import Foundation
import SwiftStateTurns

func measure(_ cell: String, _ side: String, _ n: Int) async -> (nanoseconds: Double, sink: Int) {
    let lane = ReportBenchActor()
    let laneOff = LaneOffBenchActor()
    await lane.setUp()
    await laneOff.setUp()
    let start = ContinuousClock.now
    var sink = 0
    switch (side, cell) {
    case ("lane", "emit"): sink = await lane.emitMany(n)
    case ("laneoff", "emit"): sink = await laneOff.emitMany(n)
    case ("lane", "call"): for _ in 0 ..< n { sink &+= (try? await lane.sendAndWait(.callNoop, cancellation: .ignoresCancel)) ?? 0 }
    case ("laneoff", "call"): for _ in 0 ..< n { sink &+= (try? await laneOff.sendAndWait(.callNoop, cancellation: .ignoresCancel)) ?? 0 }
    default: fatalError("unknown cell \(cell) or side \(side)")
    }
    let (seconds, attoseconds) = (ContinuousClock.now - start).components
    return ((Double(seconds) * 1e9 + Double(attoseconds) / 1e9) / Double(max(n, 1)), sink)
}

let arguments = Array(CommandLine.arguments.dropFirst())
let only = arguments.first ?? "all"
let sides = (arguments.count > 1 ? arguments[1] : "both") == "both" ? ["lane", "laneoff"] : [arguments[1]]
let iterations = arguments.count > 2 ? Int(arguments[2]) : nil
#if DEBUG
print("TurnsLaneBench: a debug build; its numbers are not comparable")
#endif
print("cell   side      ns/op")
var total = 0
let cells = only == "all" ? ["emit", "call"] : [only]
for cell in cells {
    let n = iterations ?? (cell == "call" ? 100_000 : 1_000_000)
    for side in sides {
        let result = await measure(cell, side, n)
        total &+= result.sink
        print("\(cell.padding(toLength: 6, withPad: " ", startingAt: 0)) \(side.padding(toLength: 8, withPad: " ", startingAt: 0)) \(String(format: "%8.1f", result.nanoseconds))")
    }
}
print("sink \(total & 1)")
