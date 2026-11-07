import Foundation

/// A failed write to the re-evaluation JSONL export (a full disk, an I/O error). It ends the
/// run that asked for the export: an incomplete export must not report success (#263).
public struct ReevaluationExportWriteError: Error, CustomStringConvertible {
    /// The export file, or a description of the handle when there is no path.
    public let path: String
    /// The tick whose line failed to write.
    public let tickId: Int64
    /// The error the write threw.
    public let underlying: any Error

    public var description: String {
        "export write error: tick \(tickId) to \(path): \(underlying)"
    }
}

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
    private let path: String
    private let encoder: JSONEncoder
    
    public init(outputPath: String, overwrite: Bool = true) throws {
        let url = URL(fileURLWithPath: outputPath)
        
        if overwrite, FileManager.default.fileExists(atPath: outputPath) {
            try FileManager.default.removeItem(at: url)
        }
        
        FileManager.default.createFile(atPath: outputPath, contents: nil)
        self.init(handle: try FileHandle(forWritingTo: url), path: outputPath)
    }

    /// Writes to `handle` (tests pass one whose writes fail); `path` names it in errors.
    init(handle: FileHandle, path: String = "<handle>") {
        self.handle = handle
        self.path = path
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
        var data = try encoder.encode(line)
        data.append(0x0A) // '\n'
        // The throwing write, in one call per line: the non-throwing `write(_:)` terminates the
        // process on a write error (a full disk), and two writes could leave a line without its
        // newline. The error ends the re-evaluation run that asked for the export.
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw ReevaluationExportWriteError(path: path, tickId: tickId, underlying: error)
        }
    }
    
    public func close() throws {
        try handle.close()
    }
}

