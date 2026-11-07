import Foundation
import Testing
import SwiftStateTree
@testable import GameContent

@Suite("Resolver-test tick probe")
struct TickProbeTests {
    @Test("Gaps between a land's tick starts land in 1 ms buckets; the first tick has none")
    func gaps() {
        let recorder = TickProbeRecorder()
        let probe = TickProbe(recorder: recorder)
        let t0 = ContinuousClock.now
        probe.noteTickStart(at: t0)
        probe.noteTickStart(at: t0 + .milliseconds(50))
        probe.noteTickStart(at: t0 + .microseconds(100_999))
        probe.noteTickStart(at: t0 + .seconds(3))
        let window = recorder.takeWindow()
        #expect(window.ticks == 4)
        #expect(window.buckets == ["50": 2, "1000": 1])
        #expect(window.maxGapUs == 2_899_001)
        #expect(window.quantileMs(0.5) == 50)
        #expect(window.quantileMs(0.99) == 1000)
        #expect(recorder.takeWindow() == TickGapHistogram())
    }

    @Test("Two lands' probes keep their own previous start and share the recorder")
    func perLand() {
        let recorder = TickProbeRecorder()
        let a = TickProbe(recorder: recorder), b = TickProbe(recorder: recorder)
        let t0 = ContinuousClock.now
        a.noteTickStart(at: t0)
        b.noteTickStart(at: t0 + .milliseconds(7))
        a.noteTickStart(at: t0 + .milliseconds(50))
        b.noteTickStart(at: t0 + .milliseconds(57))
        let window = recorder.takeWindow()
        #expect(window.ticks == 4 && window.buckets == ["50": 2])
    }

    @Test("The land notes its ticks through its probe; without a probe the state is the same")
    func land() async throws {
        func run(_ recorder: TickProbeRecorder?) async throws -> ResolverTestState {
            let keeper = LandKeeper<ResolverTestState>(
                definition: ResolverTest.makeLand(),
                initialState: ResolverTestState(),
                services: ResolverTest.makeServices(settings: SimulatedServiceSettings(delayMs: 0), tickRecorder: recorder),
                autoStartLoops: false
            )
            for _ in 0..<5 { await keeper.stepTickOnce() }
            return await keeper.currentState()
        }
        let recorder = TickProbeRecorder()
        let probed = try await run(recorder)
        #expect(recorder.takeWindow().ticks == 5)
        let plain = try await run(nil)
        #expect(probed.tickCount == plain.tickCount && probed.applied == plain.applied)
    }

    @Test("The writer is off without a path and refuses a bad interval")
    func writerSettings() throws {
        #expect(try TickProbeWriter.startFromEnvironment([:]) == nil)
        #expect(throws: TickProbeSettingsError.self) {
            _ = try TickProbeWriter.startFromEnvironment([TickProbeEnvKeys.path: "/dev/null", TickProbeEnvKeys.intervalMs: "50"])
        }
    }

    @Test("A line carries the window and the bucket layout")
    func line() throws {
        var window = TickGapHistogram()
        window.ticks = 3
        window.add(gapUs: 50_400)
        window.add(gapUs: 51_000)
        let data = try JSONEncoder().encode(TickProbeLine(ts: 42, window: window))
        let decoded = try JSONDecoder().decode(TickProbeLine.self, from: data)
        #expect(decoded == TickProbeLine(ts: 42, window: window))
        #expect(decoded.gaps == 2 && decoded.buckets == ["50": 1, "51": 1] && decoded.bucketWidthUs == 1000)
    }
}
