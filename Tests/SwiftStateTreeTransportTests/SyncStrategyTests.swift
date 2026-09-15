import Testing
@testable import SwiftStateTreeTransport

@Test("SyncStrategy.parse maps raw values and falls back to the default")
func testSyncStrategyParse() {
    #expect(SyncStrategy.parse(nil, default: .delta) == .delta)
    #expect(SyncStrategy.parse(nil, default: .fullSnapshot) == .fullSnapshot)
    #expect(SyncStrategy.parse("delta", default: .fullSnapshot) == .delta)
    #expect(SyncStrategy.parse("full-snapshot", default: .delta) == .fullSnapshot)
    #expect(SyncStrategy.parse("FULL-SNAPSHOT", default: .delta) == .fullSnapshot)
    #expect(SyncStrategy.parse(" full-snapshot ", default: .delta) == .fullSnapshot)
    #expect(SyncStrategy.parse("garbage", default: .delta) == .delta)
    #expect(SyncStrategy.parse("", default: .fullSnapshot) == .fullSnapshot)
}

@Test("TransportEnvConfig carries the sync strategy default when the env var is unset")
func testTransportEnvConfigSyncStrategyDefault() {
    // SYNC_STRATEGY is not set in the test process; the init default must win.
    let config = TransportEnvConfig.fromEnvironment(syncStrategyDefault: .fullSnapshot)
    #expect(config.syncStrategy == .fullSnapshot)
    let defaultConfig = TransportEnvConfig.fromEnvironment()
    #expect(defaultConfig.syncStrategy == .delta)
}

@Test("SyncStrategy.isRecognised applies the same trim+lowercase normalisation as parse")
func testSyncStrategyIsRecognised() {
    #expect(SyncStrategy.isRecognised("delta"))
    #expect(SyncStrategy.isRecognised(" FULL-SNAPSHOT "))
    #expect(!SyncStrategy.isRecognised("full_snapshot"))
    #expect(!SyncStrategy.isRecognised("garbage"))
    // Empty (after trimming) counts as "not provided", not "unrecognised" — callers
    // (e.g. TransportAdapter.init) skip warning for empty values on this basis.
    #expect(!SyncStrategy.isRecognised(""))
    #expect(!SyncStrategy.isRecognised("   "))
}
