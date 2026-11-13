import Testing
@_spi(Diagnostics) import SwiftStateTree
import SwiftStateTreeReevaluationMonitor

/// The reevaluation monitor land's fields on the typed sync tables: a field that starts taking
/// the snapshot fallback breaks this pin, so it shows up in review. Nothing is on it today.
@Suite("The reevaluation monitor's sync table fallback list")
struct ReevaluationMonitorFallbackPinTests {
    @Test("The monitor state's fallback fields, recursively")
    func monitorState() {
        let fields = syncTableFallbackFieldDescriptions(of: ReevaluationMonitorState.self)
        #expect(fields.isEmpty, "\(fields)")
    }
}
