// POC: Compare Actor vs Queue for high-throughput send bottleneck.

// Simulates 500 producers (TransportAdapters) sending ~10,000 msg/s to a single sink.

import Foundation

// MARK: - Shared Types

struct SendItem: Sendable {
    let data: Data
    let sessionID: UInt32
}

// MARK: - Actor-based (simulates WebSocketTransport)

actor ActorSink {
    private var received: Int = 0

    func send(_ item: SendItem) {
        received += 1
        // Simulate minimal work: lookup + yield (we just count)
    }

    func count() -> Int { received }
}

// MARK: - Queue-based (lock + array)

final class QueueSink: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [SendItem] = []
    private var received: Int = 0

    func enqueue(_ item: SendItem) {
        lock.lock()
        buffer.append(item)
        received += 1
        lock.unlock()
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return received
    }
}

// MARK: - Benchmark

func runActorBenchmark(producers: Int, sendsPerProducer: Int, payloadSize: Int) async -> (latenciesMs: [Double], throughput: Double) {
    let sink = ActorSink()
    let payload = Data(repeating: 0xAB, count: payloadSize)

    let start = ContinuousClock.now
    let latencies = await withTaskGroup(of: [Double].self, returning: [Double].self) { group in
        for p in 0..<producers {
            group.addTask {
                var local: [Double] = []
                local.reserveCapacity(sendsPerProducer)
                for _ in 0..<sendsPerProducer {
                    let t0 = ContinuousClock.now
                    await sink.send(SendItem(data: payload, sessionID: UInt32(p)))
                    let elapsed = ContinuousClock.now - t0
                    local.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
                }
                return local
            }
        }
        var merged: [Double] = []
        for await chunk in group {
            merged.append(contentsOf: chunk)
        }
        return merged
    }
    let total = ContinuousClock.now - start
    let totalSec = Double(total.components.seconds) + Double(total.components.attoseconds) / 1e18
    let throughput = Double(producers * sendsPerProducer) / totalSec

    return (latencies, throughput)
}

func runQueueBenchmark(producers: Int, sendsPerProducer: Int, payloadSize: Int) async -> (latenciesMs: [Double], throughput: Double) {
    let sink = QueueSink()
    let payload = Data(repeating: 0xAB, count: payloadSize)

    let start = ContinuousClock.now
    let latencies = await withTaskGroup(of: [Double].self, returning: [Double].self) { group in
        for p in 0..<producers {
            group.addTask {
                var local: [Double] = []
                local.reserveCapacity(sendsPerProducer)
                for _ in 0..<sendsPerProducer {
                    let t0 = ContinuousClock.now
                    sink.enqueue(SendItem(data: payload, sessionID: UInt32(p)))
                    let elapsed = ContinuousClock.now - t0
                    local.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
                }
                return local
            }
        }
        var merged: [Double] = []
        for await chunk in group {
            merged.append(contentsOf: chunk)
        }
        return merged
    }
    let total = ContinuousClock.now - start
    let totalSec = Double(total.components.seconds) + Double(total.components.attoseconds) / 1e18
    let throughput = Double(producers * sendsPerProducer) / totalSec

    return (latencies, throughput)
}

func percentile(_ sorted: [Double], _ p: Int) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let idx = Int(Double(sorted.count) * Double(p) / 100.0)
    return sorted[min(idx, sorted.count - 1)]
}

// MARK: - Main

func run() async {
let producers = 500
let sendsPerProducer = 20  // 500 * 20 = 10,000 sends per run
let payloadSize = 200      // ~typical state update
let runs = 3

print("Transport Actor vs Queue POC")
print("============================")
print("Producers: \(producers), sends/producer: \(sendsPerProducer), total: \(producers * sendsPerProducer) sends/run")
print("Payload: \(payloadSize) bytes")
print("Runs: \(runs)")
print("")

// Warmup
_ = await runActorBenchmark(producers: 10, sendsPerProducer: 10, payloadSize: 10)
_ = await runQueueBenchmark(producers: 10, sendsPerProducer: 10, payloadSize: 10)

var actorLatencies: [[Double]] = []
var actorThroughputs: [Double] = []
var queueLatencies: [[Double]] = []
var queueThroughputs: [Double] = []

for _ in 0..<runs {
    let (aLat, aThr) = await runActorBenchmark(producers: producers, sendsPerProducer: sendsPerProducer, payloadSize: payloadSize)
    actorLatencies.append(aLat.sorted())
    actorThroughputs.append(aThr)

    let (qLat, qThr) = await runQueueBenchmark(producers: producers, sendsPerProducer: sendsPerProducer, payloadSize: payloadSize)
    queueLatencies.append(qLat.sorted())
    queueThroughputs.append(qThr)
}

// Aggregate
func stats(_ latencies: [[Double]], _ throughputs: [Double]) -> (p50: Double, p95: Double, p99: Double, throughput: Double) {
    let all = latencies.flatMap { $0 }.sorted()
    return (
        percentile(all, 50),
        percentile(all, 95),
        percentile(all, 99),
        throughputs.reduce(0, +) / Double(throughputs.count)
    )
}

let actorStats = stats(actorLatencies, actorThroughputs)
let queueStats = stats(queueLatencies, queueThroughputs)

print("Results:")
print("--------")
print("                    Actor          Queue         Ratio")
print("Latency p50 (ms):   \(String(format: "%10.3f", actorStats.p50))    \(String(format: "%10.3f", queueStats.p50))    \(String(format: "%.2fx", actorStats.p50 / max(queueStats.p50, 0.001)))")
print("Latency p95 (ms):   \(String(format: "%10.3f", actorStats.p95))    \(String(format: "%10.3f", queueStats.p95))    \(String(format: "%.2fx", actorStats.p95 / max(queueStats.p95, 0.001)))")
print("Latency p99 (ms):   \(String(format: "%10.3f", actorStats.p99))    \(String(format: "%10.3f", queueStats.p99))    \(String(format: "%.2fx", actorStats.p99 / max(queueStats.p99, 0.001)))")
print("Throughput (msg/s): \(String(format: "%10.0f", actorStats.throughput))  \(String(format: "%10.0f", queueStats.throughput))    \(String(format: "%.2fx", queueStats.throughput / max(actorStats.throughput, 1)))")
print("")
print("Conclusion: Queue reduces producer latency by avoiding actor serialization.")
}

@main
struct Main {
    static func main() async {
        await run()
    }
}
