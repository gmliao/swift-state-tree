// EncodingBenchmark's wide-response and tickless cells (`--wide-response`,
// `--game-type visibility-test-tickless`), run in process on a small cell: the runner's input
// counters, the size of the wide reply and the perf window's toggles per iteration. The runner
// keeps its switches in process-wide statics (`InputRun`, `PerfWindowRun`), so the suite runs
// serially and restores them.

import Foundation
import Testing
import LoadTestPacing
import SwiftStateTreeMessagePack
@testable import EncodingBenchmark
@testable import GameContent
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

@Suite("EncodingBenchmark: wide-response and tickless cells", .serialized)
struct EncodingBenchmarkRunTests {
    private static let rooms = 2
    private static let playersPerRoom = 3
    private static let iterations = 4
    private static let actionsPerPlayer = 2
    /// players x iterations x actions, per room.
    private static let expectedPerRoom = playersPerRoom * iterations * actionsPerPlayer

    @Test("The wide reply doesn't fit an existential's three-word inline buffer and encodes to more than 24 bytes")
    func wideReplyIsWide() throws {
        #expect(MemoryLayout<WideVisibilityResponse>.size > 24)
        #expect(MemoryLayout<VisibilityTestResponse>.size <= 24)
        // Past a small string's 15 bytes: heap-allocated.
        #expect(VisibilityTestConfig.wideResponseTag.utf8.count == 16)

        let response = WideVisibilityResponse(
            viewEntries: 0, viewExits: 0, tickCount: 0, entityCount: 0, tag: VisibilityTestConfig.wideResponseTag)
        // Even with every number at its smallest, in the JSON encoding...
        let json = try JSONEncoder().encode(response)
        #expect(json.count > 24, "JSON: \(json.count) bytes")
        // ... and in MessagePack, where the keys are named and the tag is a string.
        let packed = try pack(MessagePackValueEncoder().encode(response))
        #expect(packed.count > 24, "MessagePack: \(packed.count) bytes")
    }

    @Test("Tick cell with --wide-response: submitted = applied = players x iterations x actions, every action accepted")
    func tickCellCounters() async throws {
        for wide in [false, true] {
            let result = await Self.run(.visibilityTest, format: .messagepackPathHash, wide: wide, ticksPerSync: 1)
            let inputs = try #require(result.inputs)
            #expect(inputs["submitted"] as? Int == Self.rooms * Self.expectedPerRoom, "wide \(wide): \(inputs)")
            #expect(inputs["applied"] as? Int == Self.rooms * Self.expectedPerRoom, "wide \(wide): \(inputs)")
            #expect(inputs["accepted"] as? Int == Self.rooms * Self.expectedPerRoom, "wide \(wide): \(inputs)")
            #expect(inputs["rejected"] as? Int == 0, "wide \(wide): \(inputs)")
            // The tick land answers with an ACK: its result carries no reply count, as before.
            #expect(inputs["replied"] == nil, "wide \(wide): \(inputs)")
            #expect(result.perfWindow == nil)
        }
    }

    @Test("Tickless cell: submitted = applied = replied = players x iterations x actions, with and without --wide-response")
    func ticklessCellCounters() async throws {
        for format in [EncodingFormat.messagepackPathHash, .opcodeJsonPathHash] {
            for wide in [false, true] {
                let result = await Self.run(.visibilityTestTickless, format: format, wide: wide, ticksPerSync: 0)
                let total = Self.rooms * Self.expectedPerRoom
                let inputs = try #require(result.inputs)
                let label = "\(format.rawValue) wide \(wide): \(inputs)"
                #expect(inputs["submitted"] as? Int == total, "\(label)")
                #expect(inputs["applied"] as? Int == total, "\(label)")
                #expect(inputs["replied"] as? Int == total, "\(label)")
                #expect(inputs["accepted"] as? Int == total, "\(label)")
                #expect(inputs["rejected"] as? Int == 0, "\(label)")
                #expect(inputs["expected"] as? Int == total, "\(label)")
                // The tickless land steps no tick.
                #expect(result.tickMs == 0, "\(label)")
            }
        }
    }

    @Test("The wide reply is a longer frame than the narrow one on the tickless land")
    func wideReplyFrameIsLarger() async {
        let narrow = await Self.run(.visibilityTestTickless, format: .messagepackPathHash, wide: false, ticksPerSync: 0)
        let wide = await Self.run(.visibilityTestTickless, format: .messagepackPathHash, wide: true, ticksPerSync: 0)
        // Same frames in; only the reply differs, so the extra bytes are the wide replies'.
        #expect(wide.totalBytes > narrow.totalBytes, "wide \(wide.totalBytes), narrow \(narrow.totalBytes)")
        let replies = Self.rooms * Self.expectedPerRoom
        // Each wide reply carries at least the 16-byte tag more than the narrow one.
        #expect((wide.totalBytes - narrow.totalBytes) / replies >= 16)
    }

    @Test("Perf window on the tickless path: nonsync opens and closes once per room and iteration, iteration once per iteration")
    func ticklessPerfWindowToggles() async throws {
        // nonsync brackets each room's span in each iteration; iteration brackets the whole
        // iteration, every room, once.
        for (mode, spans) in [(PerfWindowMode.nonsync, Self.rooms * Self.iterations), (.iteration, Self.iterations)] {
            let toggles = spans * 2
            let fifos = try ControlFifos()
            let perf = FakePerfControl(fifos: fifos, answers: toggles)
            let control = try PerfControl(controlPath: fifos.control, ackPath: fifos.ack)
            PerfWindowRun.current = PerfWindow(mode: mode, control: control)
            defer { PerfWindowRun.current = nil }

            let result = await Self.run(.visibilityTestTickless, format: .messagepackPathHash, wide: true, ticksPerSync: 0)
            let window = try #require(result.perfWindow)
            #expect(window["mode"] as? String == mode.rawValue)
            #expect(window["toggles"] as? Int == toggles, "\(mode): \(window)")
            // Perf saw each span opened and closed, alternately.
            let commands = perf.finish()
            #expect(commands == Array(repeating: ["enable", "disable"], count: spans).flatMap { $0 }, "\(mode)")
        }
    }

    @Test("A reply that doesn't come, or an input that is refused, fails the counts")
    func shortfallNamesTheRoom() {
        var counts = InputCounts(rooms: 2, expectedPerRoom: 8, countsReplies: true)
        counts.submitted = [8, 8]
        counts.applied = [8, 8]
        counts.replied = [8, 8]
        #expect(counts.shortfall(label: "t") == nil)

        counts.replied = [8, 7]
        let missingReply = counts.shortfall(label: "t")
        #expect(missingReply?.contains("room 1") == true)
        #expect(missingReply?.contains("replied 7") == true)

        counts.replied = [8, 8]
        counts.applied = [7, 8]
        #expect(counts.shortfall(label: "t")?.contains("room 0") == true)

        counts.applied = [8, 8]
        counts.rejected = [0, 1]
        #expect(counts.shortfall(label: "t")?.contains("rejected 1") == true)

        // Without counted replies (the tick land), the replies are not part of the check or the JSON.
        var tick = InputCounts(rooms: 1, expectedPerRoom: 8)
        tick.submitted = [8]
        tick.applied = [8]
        #expect(tick.shortfall(label: "t") == nil)
        #expect(tick.json["replied"] == nil)
    }

    @Test("--wide-response needs actions; the tickless land needs actions, no ticks and no capture; ticks can't be windowed on it")
    func refusals() {
        var config = BenchmarkConfig()
        config.wideResponse = true
        #expect(InputRun.refusal(config)?.contains("--wide-response needs --actions-per-player") == true)

        config = BenchmarkConfig()
        config.gameType = .visibilityTestTickless
        #expect(InputRun.refusal(config)?.contains("needs --actions-per-player") == true)

        config.actionsPerPlayer = 4
        config.inputsFromWire = true
        config.parallel = false
        #expect(InputRun.refusal(config) == nil)
        config.wideResponse = true
        #expect(InputRun.refusal(config) == nil)

        // The existing cell's refusals are unchanged: hero-defense still can't send actions.
        config.gameType = .heroDefense
        #expect(InputRun.refusal(config)?.contains("--game-type other than visibility-test") == true)
    }

    /// One serial run of `gameType` on the suite's small cell, with `--inputs-from-wire` and the
    /// suite's actions per player.
    private static func run(
        _ gameType: GameType, format: EncodingFormat, wide: Bool, ticksPerSync: Int
    ) async -> BenchmarkResult {
        InputRun.fromWire = true
        InputRun.actionsPerPlayer = actionsPerPlayer
        InputRun.wideResponse = wide
        defer {
            InputRun.fromWire = false
            InputRun.actionsPerPlayer = 0
            InputRun.wideResponse = false
        }
        return await runMultiRoomBenchmarkTestLand(
            gameType: gameType, format: format, roomCount: rooms, playersPerRoom: playersPerRoom,
            iterations: iterations, parallel: false, ticksPerSync: ticksPerSync)
    }

    // Both suites share the process-wide `InputRun` statics; nesting inside this `.serialized`
    // suite ensures they cannot run concurrently.
    @Suite("EncodingBenchmark: resolver-action cell")
    struct EncodingBenchmarkResolverTests {
    private static let rooms = 2
    private static let playersPerRoom = 3
    private static let iterations = 4
    private static let actionsPerPlayer = 2
    private static let expectedPerRoom = playersPerRoom * iterations * actionsPerPlayer

    @Test("Resolver cell: submitted = applied = replied for each encoding, with requireComplete passing",
         arguments: [EncodingFormat.messagepackPathHash, .opcodeJsonPathHash, .jsonObject])
    func resolverCellCounters(format: EncodingFormat) async throws {
        let result = await Self.runResolver(format: format)
        let total = Self.rooms * Self.expectedPerRoom
        let inputs = try #require(result.inputs)
        let label = "\(format.rawValue): \(inputs)"
        #expect(inputs["submitted"] as? Int == total, "\(label)")
        #expect(inputs["applied"] as? Int == total, "\(label)")
        #expect(inputs["replied"] as? Int == total, "\(label)")
        #expect(inputs["accepted"] as? Int == total, "\(label)")
        #expect(inputs["rejected"] as? Int == 0, "\(label)")
    }

    @Test("Resolver cell outbound bytes equal the plain tickless cell's outbound bytes per encoding",
         arguments: [EncodingFormat.messagepackPathHash, .opcodeJsonPathHash])
    func resolverCellOutboundEqualsTickless(format: EncodingFormat) async {
        let plain = await Self.runPlain(format: format)
        let resolver = await Self.runResolver(format: format)
        #expect(plain.totalBytes == resolver.totalBytes,
                "\(format.rawValue): plain \(plain.totalBytes), resolver \(resolver.totalBytes)")
    }

    @Test("Land: SetMotionResolvedAction's handler has 1 resolver; SetMotionAction's has 0")
    func resolverCountPerActionType() {
        let land = VisibilityTest.makeLand(VisibilityTestState.self, tickless: true)
        let resolvedHandler = land.actionHandlers.first(where: { $0.canHandle(SetMotionResolvedAction.self) })
        let plainHandler = land.actionHandlers.first(where: { $0.canHandle(SetMotionAction.self) })
        #expect(resolvedHandler != nil, "SetMotionResolvedAction handler not registered")
        #expect(resolvedHandler?.resolverExecutors.count == 1,
                "expected 1 resolver, got \(resolvedHandler?.resolverExecutors.count ?? -1)")
        #expect(plainHandler != nil, "SetMotionAction handler not registered")
        #expect(plainHandler?.resolverExecutors.count == 0,
                "expected 0 resolvers, got \(plainHandler?.resolverExecutors.count ?? -1)")
    }

    @Test("--resolver-action refusals: needs --actions-per-player, tickless only, not with --wide-response")
    func resolverActionRefusals() {
        var config = BenchmarkConfig()
        config.resolverAction = true
        #expect(InputRun.refusal(config)?.contains("--resolver-action needs --actions-per-player") == true)

        config.actionsPerPlayer = 2
        config.inputsFromWire = true
        config.parallel = false
        config.gameType = .visibilityTest
        #expect(InputRun.refusal(config)?.contains("only valid with --game-type visibility-test-tickless") == true)

        config.gameType = .visibilityTestTickless
        config.wideResponse = true
        #expect(InputRun.refusal(config)?.contains("--resolver-action and --wide-response") == true)

        config.wideResponse = false
        #expect(InputRun.refusal(config) == nil)
    }

    private static func runPlain(format: EncodingFormat) async -> BenchmarkResult {
        InputRun.fromWire = true
        InputRun.actionsPerPlayer = actionsPerPlayer
        defer {
            InputRun.fromWire = false
            InputRun.actionsPerPlayer = 0
        }
        return await runMultiRoomBenchmarkTestLand(
            gameType: .visibilityTestTickless, format: format, roomCount: rooms, playersPerRoom: playersPerRoom,
            iterations: iterations, parallel: false, ticksPerSync: 0)
    }

    private static func runResolver(format: EncodingFormat) async -> BenchmarkResult {
        InputRun.fromWire = true
        InputRun.actionsPerPlayer = actionsPerPlayer
        InputRun.resolverAction = true
        defer {
            InputRun.fromWire = false
            InputRun.actionsPerPlayer = 0
            InputRun.resolverAction = false
        }
        return await runMultiRoomBenchmarkTestLand(
            gameType: .visibilityTestTickless, format: format, roomCount: rooms, playersPerRoom: playersPerRoom,
            iterations: iterations, parallel: false, ticksPerSync: 0)
    }
    } // EncodingBenchmarkResolverTests
} // EncodingBenchmarkRunTests

/// Two FIFOs in a fresh temporary directory, removed on deinit.
private final class ControlFifos {
    let directory: URL
    let control: String
    let ack: String

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("benchmark-perf-control-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        control = directory.appendingPathComponent("ctl").path
        ack = directory.appendingPathComponent("ack").path
        guard mkfifo(control, 0o600) == 0, mkfifo(ack, 0o600) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

/// Plays perf's side of the control FIFOs on its own thread: reads command lines and answers each
/// with `ack\n` and a NUL, until it has answered `answers` of them.
private final class FakePerfControl: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var commands: [String] = []

    init(fifos: ControlFifos, answers: Int) {
        let controlPath = fifos.control
        let ackPath = fifos.ack
        Thread.detachNewThread { [self] in
            let control = open(controlPath, O_RDONLY)
            let ack = open(ackPath, O_WRONLY)
            defer {
                close(control)
                close(ack)
                done.signal()
            }
            var answered = 0
            while answered < answers {
                guard let line = Self.readLine(control) else { return }
                lock.withLock { commands.append(line) }
                let reply: [UInt8] = Array("ack\n".utf8) + [0]
                _ = reply.withUnsafeBytes { write(ack, $0.baseAddress, $0.count) }
                answered += 1
            }
        }
    }

    /// Waits for the fake to close its ends and returns the commands it received.
    func finish() -> [String] {
        done.wait()
        return lock.withLock { commands }
    }

    private static func readLine(_ fd: Int32) -> String? {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let count = read(fd, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count == 1 else { return nil }
            if byte == UInt8(ascii: "\n") { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
        }
    }
}
