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


    /// Get the recorded per-tick state hash for a specific tick (live ground truth).
    func getStateHash(for tickId: Int64) async throws -> String?

    /// Get recorded server events for a specific tick (for verification).
    func getServerEvents(for tickId: Int64) async throws -> [ReevaluationRecordedServerEvent]

    /// Get the maximum tick ID available in the record.
    func getMaxTickId() async throws -> Int64

    /// Get the recorded sequence watermarks for a specific tick.
    ///
    /// Returns nil when the record carries none for this tick (older records, tickless lands).
    /// Re-evaluation then leaves the sequence counter alone.
    ///
    /// Returning non-nil also asserts that `getServerEvents(for:)` returns the complete list of
    /// server events for this tick: `ReevaluationEngine` then compares server events exactly
    /// (including `sequence`) even when that list is empty, so a source that returns watermarks
    /// but drops server events reports false mismatches.
    func getSequenceWatermarks(for tickId: Int64) async throws -> ReevaluationSequenceWatermarks?

    /// Every recorded sync output and marker, in stream order (`streamIndex`).
    func getSyncStream() async throws -> [ReevaluationSyncStreamEntry]

    /// What OnInitialize did in the live run (record format 2.1, frame 0); nil before 2.1.
    func getInitializeRecord() async throws -> ReevaluationRecordedInitialize?

    /// Whether the record holds everything the recorder received (`ReevaluationRecordCompleteness`).
    func getRecordCompleteness() async throws -> ReevaluationRecordCompleteness
}

extension ReevaluationSource {
    /// Default for conformers that do not record watermarks.
    public func getSequenceWatermarks(for tickId: Int64) async throws -> ReevaluationSequenceWatermarks? {
        nil
    }

    /// Default for conformers that do not record a sync stream.
    public func getSyncStream() async throws -> [ReevaluationSyncStreamEntry] {
        []
    }

    /// Default for conformers that do not record OnInitialize.
    public func getInitializeRecord() async throws -> ReevaluationRecordedInitialize? {
        nil
    }

    /// Default: a record read whole (2.x files, frames built in memory) is complete.
    public func getRecordCompleteness() async throws -> ReevaluationRecordCompleteness {
        .complete
    }

    /// Whether the record carries a sync stream (see `ReevaluationSyncStreamPresence`).
    public func getSyncStreamPresence() async throws -> ReevaluationSyncStreamPresence {
        ReevaluationSyncStreamPresence.of(metadata: try await getMetadata(), stream: try await getSyncStream())
    }
}

// MARK: - JSONReevaluationSource

/// ReevaluationSource implementation that reads from a JSON file.
public actor JSONReevaluationSource: ReevaluationSource {
    private let metadata: ReevaluationRecordMetadata
    private let frames: [ReevaluationTickFrame]
    private let framesByTickId: [Int64: ReevaluationTickFrame]
    private let maxTickId: Int64
    
    /// Initialize from a JSON file path.
    ///
    /// Every reader opens a record file here, so this is where the version floor is enforced
    /// (#154): a record older than `ReevaluationRecordVersion.minimumSupported` throws
    /// `ReevaluationRecordVersionError.unsupported` after only its metadata is read, before its
    /// frames (whose identifiers no longer decode) are.
    public init(filePath: String) throws {
        try self.init(data: Data(contentsOf: URL(fileURLWithPath: filePath)))
    }

    /// Initialize from the bytes of a 2.x JSON record (`ReevaluationRecordFile.openSource`
    /// picks this for anything without the 3.x magic).
    public init(data: Data) throws {
        let decoder = JSONDecoder()

        decoder.dateDecodingStrategy = .iso8601

        struct ReevaluationRecordHeader: Decodable {
            let recordMetadata: ReevaluationRecordMetadata
        }
        let header = try decoder.decode(ReevaluationRecordHeader.self, from: data)
        if let recorded = header.recordMetadata.version,
           ReevaluationRecordVersion.unsupportedReason(recorded: recorded) != nil {
            throw ReevaluationRecordVersionError.unsupported(
                recorded: recorded,
                minimum: ReevaluationRecordVersion.minimumSupported
            )
        }

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

    public func getStateHash(for tickId: Int64) async throws -> String? {
        framesByTickId[tickId]?.stateHash
    }

    public func getServerEvents(for tickId: Int64) async throws -> [ReevaluationRecordedServerEvent] {
        framesByTickId[tickId]?.serverEvents ?? []
    }

    public func getMaxTickId() async throws -> Int64 {
        maxTickId
    }

    public func getSequenceWatermarks(for tickId: Int64) async throws -> ReevaluationSequenceWatermarks? {
        framesByTickId[tickId]?.sequenceWatermarks
    }

    public func getSyncStream() async throws -> [ReevaluationSyncStreamEntry] {
        ReevaluationSyncStreamEntry.stream(of: frames)
    }

    public func getInitializeRecord() async throws -> ReevaluationRecordedInitialize? {
        framesByTickId[0]?.initialize
    }

    /// The frames as read.
    public func getAllFrames() -> [ReevaluationTickFrame] { frames }
}

// MARK: - 3.0 records

/// ReevaluationSource reading a 3.0 log (`ReevaluationRecordLog`): its `turn` records merged
/// into the 2.x frame model. An incomplete file leaves out its newest tick (reported in
/// `getRecordCompleteness()`), so that tick is not replayed with partial inputs.
public actor ReevaluationRecordLogSource: ReevaluationSource {
    private let metadata: ReevaluationRecordMetadata
    private let frames: [ReevaluationTickFrame]
    private let framesByTickId: [Int64: ReevaluationTickFrame]
    private let maxTickId: Int64
    private let completeness: ReevaluationRecordCompleteness

    public init(filePath: String) throws {
        try self.init(bytes: Array(Data(contentsOf: URL(fileURLWithPath: filePath))))
    }

    /// Reads a 3.0 record. A record older than `minimumSupported` can't be 3.x, so only the
    /// format is checked here; the callers check the version as for 2.x.
    public init(bytes: [UInt8]) throws {
        let contents = try ReevaluationRecordLogReader.read(bytes)
        metadata = contents.metadata
        frames = contents.frames
        framesByTickId = Dictionary(uniqueKeysWithValues: contents.frames.map { ($0.tickId, $0) })
        maxTickId = contents.frames.map(\.tickId).max() ?? -1
        completeness = contents.completeness
    }

    public func getMetadata() async throws -> ReevaluationRecordMetadata { metadata }

    public func getActions(for tickId: Int64) async throws -> [ReevaluationRecordedAction] {
        framesByTickId[tickId]?.actions ?? []
    }

    public func getClientEvents(for tickId: Int64) async throws -> [ReevaluationRecordedClientEvent] {
        framesByTickId[tickId]?.clientEvents ?? []
    }

    public func getLifecycleEvents(for tickId: Int64) async throws -> [ReevaluationRecordedLifecycleEvent] {
        framesByTickId[tickId]?.lifecycleEvents ?? []
    }

    public func getStateHash(for tickId: Int64) async throws -> String? {
        framesByTickId[tickId]?.stateHash
    }

    public func getServerEvents(for tickId: Int64) async throws -> [ReevaluationRecordedServerEvent] {
        framesByTickId[tickId]?.serverEvents ?? []
    }

    public func getMaxTickId() async throws -> Int64 { maxTickId }

    public func getSequenceWatermarks(for tickId: Int64) async throws -> ReevaluationSequenceWatermarks? {
        framesByTickId[tickId]?.sequenceWatermarks
    }

    public func getSyncStream() async throws -> [ReevaluationSyncStreamEntry] {
        ReevaluationSyncStreamEntry.stream(of: frames)
    }

    public func getInitializeRecord() async throws -> ReevaluationRecordedInitialize? {
        framesByTickId[0]?.initialize
    }

    public func getRecordCompleteness() async throws -> ReevaluationRecordCompleteness { completeness }

    /// The frames, as the 2.6 JSON view holds them (`ReevaluationRecordFile.jsonView`).
    public func getAllFrames() -> [ReevaluationTickFrame] { frames }
}

/// Opens a record file of any supported format.
public enum ReevaluationRecordFile {
    /// A 3.x log (`SSTR` magic) opens `ReevaluationRecordLogSource`; anything else the 2.x
    /// `JSONReevaluationSource`, which rejects records older than `minimumSupported`.
    public static func openSource(filePath: String) throws -> any ReevaluationSource {
        try openSource(data: Data(contentsOf: URL(fileURLWithPath: filePath)))
    }

    public static func openSource(data: Data) throws -> any ReevaluationSource {
        if ReevaluationRecordLog.hasMagic(data) {
            return try ReevaluationRecordLogSource(bytes: Array(data))
        }
        return try JSONReevaluationSource(data: data)
    }

    /// The 2.6 JSON view of a 3.0 record's bytes (any other bytes are returned unchanged).
    public static func jsonView(ofRecordData data: Data) throws -> Data {
        guard ReevaluationRecordLog.hasMagic(data) else { return data }
        let contents = try ReevaluationRecordLogReader.read(Array(data))
        return try jsonViewData(metadata: contents.metadata, frames: contents.frames)
    }

    /// Rewrites a 3.0 record file in place as its JSON view: for tests that edit a saved record
    /// by hand (a 2.x file is left as it is).
    package static func convertToJSONViewForTesting(atPath path: String) throws {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        guard ReevaluationRecordLog.hasMagic(data) else { return }
        try jsonView(ofRecordData: data).write(to: url)
    }

    static func jsonViewData(metadata: ReevaluationRecordMetadata, frames: [ReevaluationTickFrame]) throws -> Data {
        struct View: Encodable {
            let recordMetadata: ReevaluationRecordMetadata
            let tickFrames: [ReevaluationTickFrame]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(View(recordMetadata: metadata, tickFrames: frames))
    }

    /// The 2.6 JSON shape (`recordMetadata`, `tickFrames`, pretty-printed, sorted keys) of a
    /// record, for reading by hand. Not a recording format: replay doesn't read it back.
    public static func jsonView(of source: any ReevaluationSource) async throws -> Data {
        let metadata = try await source.getMetadata()
        let frames: [ReevaluationTickFrame]
        if let log = source as? ReevaluationRecordLogSource {
            frames = await log.getAllFrames()
        } else if let json = source as? JSONReevaluationSource {
            frames = await json.getAllFrames()
        } else {
            frames = []
        }
        return try jsonViewData(metadata: metadata, frames: frames)
    }
}
