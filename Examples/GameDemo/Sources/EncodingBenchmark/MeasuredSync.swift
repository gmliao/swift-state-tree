// Examples/GameDemo/Sources/EncodingBenchmark/MeasuredSync.swift
//
// Counting bytes after the outbound writer drained (#160). Since #86 a `TransportAdapter` hands
// its frames to the transport through an asynchronous ordered writer, and skips a sync cycle
// while the writer still holds an earlier one (back-pressure). Bytes read right after
// `syncNow()` can therefore miss frames still in the writer, or include the previous window's,
// and a skipped cycle coalesces into the next: bytes per sync then depend on timing.

import Foundation
@_spi(Diagnostics) import SwiftStateTreeTransport
import SwiftStateTree

enum MeasuredSync {
    /// Waits until every adapter handed all frames enqueued so far to its transport. Exits the
    /// run if one does not drain: its counts would be incomplete.
    static func drain<State: StateNodeProtocol>(_ adapters: [TransportAdapter<State>]) async {
        for adapter in adapters {
            guard await adapter.waitForOutboundDrain(timeout: .seconds(30)) else {
                print("Error: an adapter's outbound writer did not drain within 30 s; byte counts would be incomplete")
                exit(1)
            }
        }
    }

    /// Sync cycles the adapters skipped so far (back-pressure or a cycle in flight).
    static func skipCount<State: StateNodeProtocol>(_ adapters: [TransportAdapter<State>]) async -> Int {
        var total = 0
        for adapter in adapters {
            let skips = await adapter.syncSkipCounts()
            total += skips.busy + skips.outboundBacklog
        }
        return total
    }

    /// The adapters' frame prefix cache counts so far, summed (`FramePrefixCacheCounts`).
    static func prefixCacheCounts<State: StateNodeProtocol>(_ adapters: [TransportAdapter<State>]) async -> FramePrefixCacheCounts {
        var total = FramePrefixCacheCounts()
        for adapter in adapters {
            total = total + (await adapter.framePrefixCacheCounts())
        }
        return total
    }

    /// Exits the run when a measured sync was skipped: its changes went out in a later cycle, so
    /// bytes per sync would not describe one sync each.
    static func requireNoSkips(_ skips: Int, label: String) {
        guard skips == 0 else {
            print("Error: \(skips) measured sync cycle(s) were skipped (\(label)); bytes per sync would be wrong")
            exit(1)
        }
    }
}
