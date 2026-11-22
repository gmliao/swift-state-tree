// The mailbox's cost per operation on an empty mailbox (Notes/plans/2026-11-21-turn-core-mailbox.md
// §3.8): an emit and a call on a machine that takes mail (side `mailbox`), against the same
// machine with `Mail == Never` (side `mailboxoff`). Recorded, not gated. Release builds only.
//
//   TurnsMailboxBench [emit|call|all] [mailbox|mailboxoff|both] [iterations]
//
// One cell and one side per run is what a normal counter (`perf stat`) wraps. A separate target
// from TurnsBench: in one binary, LLVM merges identical specializations of the two machines with
// TurnsBench's, and the merged thunks move its gated cells.

import Foundation
import SwiftStateTurns

func measure(_ cell: String, _ side: String, _ n: Int) async -> (nanoseconds: Double, sink: Int) {
    let mailbox = MailBenchActor()
    let mailboxOff = MailboxOffBenchActor()
    await mailbox.setUp()
    await mailboxOff.setUp()
    let start = ContinuousClock.now
    var sink = 0
    switch (side, cell) {
    case ("mailbox", "emit"): sink = await mailbox.emitMany(n)
    case ("mailboxoff", "emit"): sink = await mailboxOff.emitMany(n)
    case ("mailbox", "call"): for _ in 0 ..< n { sink &+= (try? await mailbox.sendAndWait(.callNoop, cancellation: .ignoresCancel)) ?? 0 }
    case ("mailboxoff", "call"): for _ in 0 ..< n { sink &+= (try? await mailboxOff.sendAndWait(.callNoop, cancellation: .ignoresCancel)) ?? 0 }
    default: fatalError("unknown cell \(cell) or side \(side)")
    }
    let (seconds, attoseconds) = (ContinuousClock.now - start).components
    return ((Double(seconds) * 1e9 + Double(attoseconds) / 1e9) / Double(max(n, 1)), sink)
}

let arguments = Array(CommandLine.arguments.dropFirst())
let only = arguments.first ?? "all"
let sides = (arguments.count > 1 ? arguments[1] : "both") == "both" ? ["mailbox", "mailboxoff"] : [arguments[1]]
let iterations = arguments.count > 2 ? Int(arguments[2]) : nil
#if DEBUG
print("TurnsMailboxBench: a debug build; its numbers are not comparable")
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
