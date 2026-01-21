import Foundation

// MARK: - ReevaluationSource Protocol

/// Protocol for reading recorded inputs/outputs during deterministic re-evaluation.
public protocol ReevaluationSource: Sendable {
    /// Get record metadata (required for deterministic re-evaluation setup).
    func getMetadata() async throws -> ReevaluationRecordMetadata

    /// Get actions for a specific tick.
    func getActions(for tickId: Int64) async throws -> [ReevaluationRecordedAction]
    
    /// Get client events for a specific tick.
    func getClientEvents(for tickId: Int64) async throws -> [ReevaluationRecordedClientEvent]

    /// Get lifecycle events for a specific tick.
    func getLifecycleEvents(for tickId: Int64) async throws -> [ReevaluationRecordedLifecycleEvent]
    
    /// Get server events for a specific tick.
    func getServerEvents(for tickId: Int64) async throws -> [ReevaluationRecordedServerEvent]
    
    /// Get the maximum tick ID available in the record.
    func getMaxTickId() async throws -> Int64
}

// MARK: - JSONReevaluationSource

/// ReevaluationSource implementation that reads from a JSON file.
public actor JSONReevaluationSource: ReevaluationSource {
    private let metadata: ReevaluationRecordMetadata
    private let frames: [ReevaluationTickFrame]
    private let framesByTickId: [Int64: ReevaluationTickFrame]
    private let maxTickId: Int64
    
    /// Initialize from a JSON file path.
    public init(filePath: String) throws {
        let url = URL(fileURLWithPath: filePath)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()

        decoder.dateDecodingStrategy = .iso8601

        struct ReevaluationRecordFile: Codable {
            let recordMetadata: ReevaluationRecordMetadata
            let tickFrames: [ReevaluationTickFrame]
        }

        let recordFile = try decoder.decode(ReevaluationRecordFile.self, from: data)
        self.metadata = recordFile.recordMetadata
        let frames = recordFile.tickFrames
        
        self.frames = frames
        self.framesByTickId = Dictionary(uniqueKeysWithValues: frames.map { ($0.tickId, $0) })
        self.maxTickId = frames.map { $0.tickId }.max() ?? -1
    }
    
    /// Initialize from tick frames (for testing).
    public init(metadata: ReevaluationRecordMetadata, frames: [ReevaluationTickFrame]) {
        self.metadata = metadata
        self.frames = frames
        self.framesByTickId = Dictionary(uniqueKeysWithValues: frames.map { ($0.tickId, $0) })
        self.maxTickId = frames.map { $0.tickId }.max() ?? -1
    }

    public func getMetadata() async throws -> ReevaluationRecordMetadata {
        metadata
    }
    
    public func getActions(for tickId: Int64) async throws -> [ReevaluationRecordedAction] {
        framesByTickId[tickId]?.actions ?? []
    }
    
    public func getClientEvents(for tickId: Int64) async throws -> [ReevaluationRecordedClientEvent] {
        framesByTickId[tickId]?.clientEvents ?? []
    }

    public func getLifecycleEvents(for tickId: Int64) async throws -> [ReevaluationRecordedLifecycleEvent] {
        framesByTickId[tickId]?.lifecycleEvents ?? []
    }
    
    public func getServerEvents(for tickId: Int64) async throws -> [ReevaluationRecordedServerEvent] {
        framesByTickId[tickId]?.serverEvents ?? []
    }
    
    public func getMaxTickId() async throws -> Int64 {
        maxTickId
    }
}
