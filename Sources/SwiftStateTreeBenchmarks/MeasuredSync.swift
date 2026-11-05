// Sources/SwiftStateTreeBenchmarks/MeasuredSync.swift

import Foundation
import SwiftStateTree
@_spi(Diagnostics) import SwiftStateTreeTransport

/// Since the ordered outbound writer, a sync cycle's frames reach the transport asynchronously,
/// and a cycle is skipped while the writer still holds an earlier one. Benchmarks drain before
/// counting bytes and count the cycles that were skipped (#160).
enum MeasuredSync {
    /// Waits until every frame the adapter produced was handed to the transport; exits if the
    /// writer does not drain, since the counts would be wrong.
    static func drain<State: StateNodeProtocol>(_ adapter: TransportAdapter<State>) async {
        guard await adapter.waitForOutboundDrain(timeout: .seconds(30)) else {
            print("❌ Outbound writer did not drain within 30 s: byte counts would be incomplete.")
            exit(1)
        }
    }

    /// Sync cycles skipped so far: rejected while another cycle was in flight, or deferred by
    /// back-pressure.
    static func skipCount<State: StateNodeProtocol>(_ adapter: TransportAdapter<State>) async -> Int {
        let counts = await adapter.syncSkipCounts()
        return counts.busy + counts.outboundBacklog
    }

    /// Exits unless no measured cycle was skipped: a skipped cycle's bytes land in a later one.
    static func requireNoSkips(_ skips: Int, label: String) {
        guard skips == 0 else {
            print("❌ \(label): \(skips) measured sync cycle(s) were skipped; bytes and times are not per cycle.")
            exit(1)
        }
    }
}
