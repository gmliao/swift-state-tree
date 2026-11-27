import SwiftStateTurns

/// Runs `BarrierMailMachine` on a test clock, with its mailbox. Diagnostics go to the fixture.
actor BarrierMailActor: TurnActor {
    let core: TurnCore<BarrierMailMachine>
    nonisolated let mailbox: TurnMailbox<String>?
    nonisolated let fixture: Fixture
    nonisolated let clock: TestClock

    init(fixture: Fixture) {
        let clock = TestClock(fixture: fixture)
        self.fixture = fixture
        self.clock = clock
        let core = TurnCore(BarrierMailMachine(), queueLimit: 64, maxReleasesPerBatch: 16, clock: clock)
        core.onDiagnostic = { event in fixture.observe(event) }
        self.core = core
        self.mailbox = core.mailbox
    }

    @concurrent nonisolated func perform(_ effect: BarrierMailMachine.Effect) async -> BarrierMailMachine.Input? {
        switch effect {}
    }

    func flush(_ outputs: consuming [Int]) {}

    var log: [String] { core.read { $0.log } }
    var ordinal: UInt64 { core.nextOrdinalForTesting }
    var table: [Int] { [core.barrierWaitersForTesting, core.cancelledCallersForTesting] }
}
