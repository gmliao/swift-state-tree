import Testing
@testable import SwiftStateTreeTransport

@Suite("Sync tables: the fallback fields are logged once per state type")
struct SyncTableFallbackLogTests {
    @Test("Only the first call for a type is first")
    func oncePerType() {
        let log = SyncTableFallbackLog()
        #expect(log.isFirst(Int.self))
        #expect(!log.isFirst(Int.self))
        #expect(log.isFirst(String.self))
        #expect(!log.isFirst(Int.self))
    }
}
