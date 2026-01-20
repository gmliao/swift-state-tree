import Foundation

// MARK: - ActionSource Protocol

/// Protocol for reading recorded actions and events during replay
public protocol ActionSource: Sendable {
    /// Get recording metadata (required for deterministic replay setup)
    func getMetadata() async throws -> RecordingMetadata

    /// Get actions for a specific tick
    func getActions(for tickId: Int64) async throws -> [RecordedAction]
    
    /// Get client events for a specific tick
    func getClientEvents(for tickId: Int64) async throws -> [RecordedClientEvent]

    /// Get lifecycle events for a specific tick
    func getLifecycleEvents(for tickId: Int64) async throws -> [RecordedLifecycleEvent]
    
    /// Get server events for a specific tick
    func getServerEvents(for tickId: Int64) async throws -> [RecordedServerEvent]
    
    /// Get the maximum tick ID available in the recording
    func getMaxTickId() async throws -> Int64
}

// MARK: - JSONActionSource

/// ActionSource implementation that reads from a JSON file
public actor JSONActionSource: ActionSource {
    private let metadata: RecordingMetadata
    private let frames: [RecordingFrame]
    private let framesByTickId: [Int64: RecordingFrame]
    private let maxTickId: Int64
    
    /// Initialize from a JSON file path
    public init(filePath: String) throws {
        let url = URL(fileURLWithPath: filePath)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()

        decoder.dateDecodingStrategy = .iso8601

        struct RecordingFile: Codable {
            let metadata: RecordingMetadata
            let frames: [RecordingFrame]
        }

        let recordingFile = try decoder.decode(RecordingFile.self, from: data)
        self.metadata = recordingFile.metadata
        let frames = recordingFile.frames
        
        self.frames = frames
        self.framesByTickId = Dictionary(uniqueKeysWithValues: frames.map { ($0.tickId, $0) })
        self.maxTickId = frames.map { $0.tickId }.max() ?? -1
    }
    
    /// Initialize from RecordingFrame array (for testing)
    public init(metadata: RecordingMetadata, frames: [RecordingFrame]) {
        self.metadata = metadata
        self.frames = frames
        self.framesByTickId = Dictionary(uniqueKeysWithValues: frames.map { ($0.tickId, $0) })
        self.maxTickId = frames.map { $0.tickId }.max() ?? -1
    }

    public func getMetadata() async throws -> RecordingMetadata {
        metadata
    }
    
    public func getActions(for tickId: Int64) async throws -> [RecordedAction] {
        return framesByTickId[tickId]?.actions ?? []
    }
    
    public func getClientEvents(for tickId: Int64) async throws -> [RecordedClientEvent] {
        return framesByTickId[tickId]?.clientEvents ?? []
    }

    public func getLifecycleEvents(for tickId: Int64) async throws -> [RecordedLifecycleEvent] {
        return framesByTickId[tickId]?.lifecycleEvents ?? []
    }
    
    public func getServerEvents(for tickId: Int64) async throws -> [RecordedServerEvent] {
        return framesByTickId[tickId]?.serverEvents ?? []
    }
    
    public func getMaxTickId() async throws -> Int64 {
        return maxTickId
    }
}
