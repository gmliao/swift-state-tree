import SwiftStateTree

@StateNodeBuilder
public struct ReevaluationMonitorState: StateNodeProtocol {
    @Sync(.broadcast)
    var recordFilePath: String = ""

    @Sync(.broadcast)
    var status: String = "idle" // idle, loading, verifying, paused, completed, failed

    @Sync(.broadcast)
    var isPaused: Bool = false

    @Sync(.broadcast)
    var totalTicks: Int = 0

    @Sync(.broadcast)
    var processedTicks: Int = 0

    @Sync(.broadcast)
    var correctTicks: Int = 0

    @Sync(.broadcast)
    var mismatchedTicks: Int = 0

    @Sync(.broadcast)
    var currentTickId: Int64 = 0

    @Sync(.broadcast)
    var currentExpectedHash: String = ""

    @Sync(.broadcast)
    var currentActualHash: String = ""

    @Sync(.broadcast)
    var currentIsMatch: Bool = true

    @Sync(.broadcast)
    var errorMessage: String = ""

    public init() {}
}

public struct TickMismatch: Codable, Sendable {
    public let tickId: Int64
    public let computed: String
    public let recorded: String

    public init(tickId: Int64, computed: String, recorded: String) {
        self.tickId = tickId
        self.computed = computed
        self.recorded = recorded
    }
}
