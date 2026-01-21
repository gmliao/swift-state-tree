import Foundation

/// JSONL exporter for deterministic re-evaluation playback.
///
/// Each line is a standalone JSON object containing:
/// - tickId
/// - full StateSnapshot (mode: .all)
/// - optional deterministic stateHash
/// - recorded serverEvents for that tick
public actor ReevaluationJsonlExporter {
    public struct TickLine: Codable, Sendable {
        public let tickId: Int64
        public let stateSnapshot: StateSnapshot
        public let stateHash: String?
        public let serverEvents: [ReevaluationRecordedServerEvent]
    }
    
    private let handle: FileHandle
    private let encoder: JSONEncoder
    
    public init(outputPath: String, overwrite: Bool = true) throws {
        let url = URL(fileURLWithPath: outputPath)
        
        if overwrite, FileManager.default.fileExists(atPath: outputPath) {
            try FileManager.default.removeItem(at: url)
        }
        
        FileManager.default.createFile(atPath: outputPath, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }
    
    deinit {
        try? handle.close()
    }
    
    public func writeTick(
        tickId: Int64,
        stateSnapshot: StateSnapshot,
        stateHash: String?,
        serverEvents: [ReevaluationRecordedServerEvent]
    ) throws {
        let line = TickLine(
            tickId: tickId,
            stateSnapshot: stateSnapshot,
            stateHash: stateHash,
            serverEvents: serverEvents
        )
        let data = try encoder.encode(line)
        handle.write(data)
        handle.write(Data([0x0A])) // '\n'
    }
    
    public func close() throws {
        try handle.close()
    }
}

