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

    /// Get a tickless land's recorded passes for a specific tick, in live order (record format
    /// 3.1, `ReevaluationRecordedPass`). Empty for tick lands and older records: re-evaluation
    /// then applies the tick's inputs in one pass, in `(resolvedAtTick, sequence)` order.
    func getPasses(for tickId: Int64) async throws -> [ReevaluationRecordedPass]

    /// Get server inputs for a specific tick (record format 3.2, #387). Empty in older records.
    func getServerInputs(for tickId: Int64) async throws -> [ReevaluationRecordedServerInput]

    /// A tick land's refused inputs for a specific tick (record format 3.5, #586,
    /// `ReevaluationTickFrame.rejected`). Empty when none was, and in older records.
    func getRejected(for tickId: Int64) async throws -> [Int64]

    /// Every recorded sync output and marker, in stream order (`streamIndex`).
    func getSyncStream() async throws -> [ReevaluationSyncStreamEntry]

    /// The failure that ended the live land and the tick of the frame that holds it (record
    /// format 3.4, #535 D9); nil when the land didn't fail or the record is older.
    func getLandFailure() async throws -> (tickId: Int64, failure: LandFailure)?

    /// What OnInitialize did in the live run (record format 2.1, frame 0); nil before 2.1.
    func getInitializeRecord() async throws -> ReevaluationRecordedInitialize?

    /// Whether the record holds everything the recorder received (`ReevaluationRecordCompleteness`).
    func getRecordCompleteness() async throws -> ReevaluationRecordCompleteness

    /// Whether a record older than 3.3 holds a string or a map key that is not NFC (#446): its
    /// state hashes may then differ from this build's (`ReevaluationRecordVersion.hashIncomparability`).
    func getHoldsNonNFCText() async throws -> Bool

    /// True only when this source parsed its frames from JSON bytes — the two JSON-reading
    /// initializers (`init(data:)` and `init(filePath:)`). JSON's number representation loses the
    /// float/integer distinction, so a runner reading such a source decodes with the integral-float
    /// allowance. Sources that hold canonical frames built in memory (`init(metadata:frames:)`) or
    /// that read a 3.x binary record never set this, and their runners decode strictly.
    /// A source that wraps another source and forwards its reads must also forward this property.
    nonisolated var readsJSONRecord: Bool { get }
}

extension ReevaluationSource {
    /// Default for conformers that do not record watermarks.
    public func getSequenceWatermarks(for tickId: Int64) async throws -> ReevaluationSequenceWatermarks? {
        nil
    }

    /// Default for conformers that do not record passes.
    public func getPasses(for tickId: Int64) async throws -> [ReevaluationRecordedPass] {
        []
    }

    /// Default for conformers that record no refused inputs.
    public func getRejected(for tickId: Int64) async throws -> [Int64] {
        []
    }

    /// Default for conformers that record no land failure.
    public func getLandFailure() async throws -> (tickId: Int64, failure: LandFailure)? {
        nil
    }

    /// Default for conformers that do not record server inputs.
    public func getServerInputs(for tickId: Int64) async throws -> [ReevaluationRecordedServerInput] {
        []
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

    /// Default for conformers that do not read a file: frames built in memory hold NFC IDs.
    public func getHoldsNonNFCText() async throws -> Bool {
        false
    }

    /// Default for conformers that hold canonical frames built in memory: no JSON was parsed.
    public nonisolated var readsJSONRecord: Bool { false }

    /// Whether the record carries a sync stream (see `ReevaluationSyncStreamPresence`).
    public func getSyncStreamPresence() async throws -> ReevaluationSyncStreamPresence {
        ReevaluationSyncStreamPresence.of(metadata: try await getMetadata(), stream: try await getSyncStream())
    }
}

// MARK: - Record content checks

/// A record whose content isn't one a live run writes (#639, #640, #641, #729). A source refuses it
/// when the record is opened, and a replay resolve when it reads the tick, so the replay run
/// fails with the cause and the process goes on.
public enum ReevaluationRecordContentError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    /// Two frames of the record hold the same tick (#639).
    case duplicateTickId(Int64)
    /// A frame's tick is outside `0 ..< Int64.max` (#640). A live keeper numbers its ticks from 0
    /// and can't record `Int64.max`: advancing its tick counter past it would overflow first.
    case tickIdOutOfRange(Int64)
    /// A recorded event target that `ReevaluationEventTargetRecord.from(_:)` doesn't write (#641).
    case malformedEventTarget(kind: String, idCount: Int)
    /// A recorded output sequence (the initialize record's, or a sequence counter watermark) outside
    /// `0 ..< Int64.max` (#729). A live keeper numbers from 0 and can't record `Int64.max`: taking
    /// the next number from it would overflow first.
    case sequenceOutOfRange(Int64)
    /// A sync output's or seed marker's `afterPass` below 0 (#729). A live tickless land numbers
    /// its passes from 1 and records 0 before the first.
    case afterPassOutOfRange(Int64)
    /// A replay on a re-evaluation keeper needed a next output sequence past `Int64.max` (#741). A
    /// value inside `0 ..< Int64.max` can still leave too little room: the number of numbers taken
    /// after it comes from the land's code, so only the replay itself can tell. A live keeper's
    /// counter can't reach this, so only a record whose counter was set near the top gets here.
    case sequenceExhausted
    /// The record's last tick is past the run length a reader allows (#728). A replay steps every
    /// tick from 0 to the last one, the ticks without a frame included, so a last tick of
    /// `lastTick` costs `lastTick + 1` steps; `limit` is the most steps allowed.
    case replayTooLong(lastTick: Int64, limit: Int64)

    public var description: String {
        switch self {
        case .duplicateTickId(let tickId):
            "the record holds two frames for tick \(tickId); a live run writes one frame per tick"
        case .tickIdOutOfRange(let tickId):
            "the record holds a frame for tick \(tickId), outside the ticks a live run writes (0 ..< \(Int64.max))"
        case let .malformedEventTarget(kind, idCount):
            "a recorded event target of kind '\(kind)' with \(idCount) IDs; a live run writes 'all' with none, 'player', 'client' or 'session' with one, and 'players' with any number"
        case .sequenceOutOfRange(let sequence):
            "the record holds the output sequence \(sequence), outside the sequences a live run writes (0 ..< \(Int64.max))"
        case .afterPassOutOfRange(let afterPass):
            "the record holds a sync entry that read after pass \(afterPass); a live run writes 0 or more"
        case .sequenceExhausted:
            "the replay needed an output sequence past \(Int64.max): the record's sequence counter leaves too little room for the events the land emits"
        case let .replayTooLong(lastTick, limit):
            "the record's last tick is \(lastTick), so a replay would take \(lastTick) + 1 steps, past the limit of \(limit)"
        }
    }

    /// The run's status shows this text (the runner service reports `localizedDescription`).
    public var errorDescription: String? { description }

    /// Whether this is `replayTooLong`, whatever its numbers.
    public var isReplayTooLong: Bool {
        if case .replayTooLong = self { return true }
        return false
    }
}

enum ReevaluationRecordContentCheck {
    /// The frames indexed by tick. Throws at the first frame, in record order, whose tick is out
    /// of range or is already indexed, or that holds a sequence or pass ordinal out of range (#729).
    /// After every frame has passed, throws `replayTooLong` when the last tick + 1 is past
    /// `maxReplayTicks` (#728).
    static func checkedIndex(
        _ frames: [ReevaluationTickFrame],
        maxReplayTicks: Int64
    ) throws -> [Int64: ReevaluationTickFrame] {
        var index: [Int64: ReevaluationTickFrame] = [:]
        index.reserveCapacity(frames.count)
        var lastTick: Int64 = -1
        for frame in frames {
            guard frame.tickId >= 0, frame.tickId < Int64.max else {
                throw ReevaluationRecordContentError.tickIdOutOfRange(frame.tickId)
            }
            guard index.updateValue(frame, forKey: frame.tickId) == nil else {
                throw ReevaluationRecordContentError.duplicateTickId(frame.tickId)
            }
            try checkNumbers(of: frame)
            lastTick = max(lastTick, frame.tickId)
        }
        // Every tick is below `Int64.max`, so the sum can't overflow.
        guard lastTick + 1 <= maxReplayTicks else {
            throw ReevaluationRecordContentError.replayTooLong(lastTick: lastTick, limit: maxReplayTicks)
        }
        return index
    }

    /// Throws when a sequence or pass ordinal of `frame` is one a live run can't write, before
    /// replay does arithmetic on it: the next sequence after `Int64.max`, or the pass before an
    /// `afterPass` of `Int64.min`.
    private static func checkNumbers(of frame: ReevaluationTickFrame) throws {
        func sequence(_ value: Int64?) throws {
            if let value, value < 0 || value == Int64.max {
                throw ReevaluationRecordContentError.sequenceOutOfRange(value)
            }
        }
        func afterPass(_ value: Int64?) throws {
            if let value, value < 0 {
                throw ReevaluationRecordContentError.afterPassOutOfRange(value)
            }
        }
        try sequence(frame.initialize?.sequence)
        try sequence(frame.sequenceBeforeInputs)
        try sequence(frame.sequenceBeforeTickHandler)
        for pass in frame.passes { try sequence(pass.sequenceBefore) }
        for output in frame.syncOutputs { try afterPass(output.afterPass) }
        for marker in frame.syncMarkers { try afterPass(marker.afterPass) }
    }
}

// MARK: - JSONReevaluationSource

/// ReevaluationSource implementation that reads from a JSON file.
public actor JSONReevaluationSource: ReevaluationSource {
    private let metadata: ReevaluationRecordMetadata
    private let frames: [ReevaluationTickFrame]
    private let framesByTickId: [Int64: ReevaluationTickFrame]
    private let maxTickId: Int64
    private let holdsNonNFCText: Bool
    private let _readsJSONRecord: Bool
    public nonisolated var readsJSONRecord: Bool { _readsJSONRecord }
    
    /// Initialize from a JSON file path.
    ///
    /// Every reader opens a record file here, so this is where the version floor is enforced
    /// (#154): a record older than `ReevaluationRecordVersion.minimumSupported` throws
    /// `ReevaluationRecordVersionError.unsupported` after only its metadata is read, before its
    /// frames (whose identifiers no longer decode) are.
    public init(filePath: String, maxReplayTicks: Int64 = ReevaluationRecordFile.defaultMaxReplayTicks) throws {
        precondition(maxReplayTicks >= 1, "maxReplayTicks must be at least 1")
        try self.init(data: Data(contentsOf: URL(fileURLWithPath: filePath)), maxReplayTicks: maxReplayTicks)
    }

    /// Initialize from the bytes of a 2.x JSON record (`ReevaluationRecordFile.openSource`
    /// picks this for anything without the 3.x magic).
    ///
    /// Throws `ReevaluationRecordContentError.replayTooLong` when the record's last tick + 1 is past
    /// `maxReplayTicks` (#728), which must be at least 1.
    public init(data: Data, maxReplayTicks: Int64 = ReevaluationRecordFile.defaultMaxReplayTicks) throws {
        precondition(maxReplayTicks >= 1, "maxReplayTicks must be at least 1")
        // Refused before it is parsed when it nests deeper than a 3.x record can
        // (`CanonicalMessagePack.maxDepth`): the decode and `holdsNonNFCText` below recurse per
        // level (#362). A recorded payload is checked again at its own limit when it is
        // replayed (`InboundPayloadDecoding`).
        try PayloadNesting.checkJSON(data, limit: CanonicalMessagePack.maxDepth)
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
        // A record is untrusted input: a duplicate tick or an out-of-range number throws, it never traps (#639, #640, #729).
        self.framesByTickId = try ReevaluationRecordContentCheck.checkedIndex(frames, maxReplayTicks: maxReplayTicks)
        self.maxTickId = frames.map { $0.tickId }.max() ?? -1
        // Every 2.x record is older than 3.3 (#446).
        self.holdsNonNFCText = Self.holdsNonNFCText(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
        self._readsJSONRecord = true
    }

    private static func holdsNonNFCText(_ value: Any) -> Bool {
        if let text = value as? String { return !SnapshotValue.isNFC(text) }
        if let array = value as? [Any] { return array.contains(where: holdsNonNFCText) }
        if let object = value as? [String: Any] {
            return object.contains { !SnapshotValue.isNFC($0.key) || holdsNonNFCText($0.value) }
        }
        return false
    }

    public func getHoldsNonNFCText() async throws -> Bool { holdsNonNFCText }
    
    /// Initialize from tick frames (for testing). The frames are taken as this build's: their
    /// text is not scanned, and `getHoldsNonNFCText()` is false.
    ///
    /// - Precondition: every frame's tick is in `0 ..< Int64.max`, no two frames share a tick,
    ///   and no sequence or `afterPass` in them is out of range (`ReevaluationRecordContentError`).
    ///   The frames come from code, so a frame that breaks this stops the process; a record read
    ///   from bytes or a file throws instead (#639, #729). The run length is not bounded here
    ///   (`maxReplayTicks`, #728): the frames come from code. The same holds for a `LandKeeper`
    ///   built directly in `.reevaluation` mode with a custom `ReevaluationSource`: no run length
    ///   is checked, so a host that passes externally supplied frames reads them with a checked
    ///   source (`ReevaluationRecordFile.openSource`).
    public init(metadata: ReevaluationRecordMetadata, frames: [ReevaluationTickFrame]) {
        self.metadata = metadata
        self.frames = frames
        do {
            self.framesByTickId = try ReevaluationRecordContentCheck.checkedIndex(frames, maxReplayTicks: Int64.max)
        } catch {
            preconditionFailure("JSONReevaluationSource(metadata:frames:): \(error)")
        }
        self.maxTickId = frames.map { $0.tickId }.max() ?? -1
        self.holdsNonNFCText = false
        self._readsJSONRecord = false
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

    public func getServerInputs(for tickId: Int64) async throws -> [ReevaluationRecordedServerInput] {
        framesByTickId[tickId]?.serverInputs ?? []
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

    public func getPasses(for tickId: Int64) async throws -> [ReevaluationRecordedPass] {
        framesByTickId[tickId]?.passes ?? []
    }

    public func getRejected(for tickId: Int64) async throws -> [Int64] {
        framesByTickId[tickId]?.rejected ?? []
    }

    public func getLandFailure() async throws -> (tickId: Int64, failure: LandFailure)? {
        frames.first { $0.landFailure != nil }.flatMap { frame in frame.landFailure.map { (frame.tickId, $0) } }
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
    private let holdsNonNFCText: Bool

    public init(filePath: String, maxReplayTicks: Int64 = ReevaluationRecordFile.defaultMaxReplayTicks) throws {
        precondition(maxReplayTicks >= 1, "maxReplayTicks must be at least 1")
        try self.init(bytes: Array(Data(contentsOf: URL(fileURLWithPath: filePath))), maxReplayTicks: maxReplayTicks)
    }

    /// Reads a 3.0 record. A record older than `minimumSupported` can't be 3.x, so only the
    /// format is checked here; the callers check the version as for 2.x. Throws
    /// `ReevaluationRecordContentError.replayTooLong` when the last tick + 1 is past
    /// `maxReplayTicks` (#728), which must be at least 1.
    public init(bytes: [UInt8], maxReplayTicks: Int64 = ReevaluationRecordFile.defaultMaxReplayTicks) throws {
        precondition(maxReplayTicks >= 1, "maxReplayTicks must be at least 1")
        let contents = try ReevaluationRecordLogReader.read(bytes)
        metadata = contents.metadata
        frames = contents.frames
        // The assembler merges one tick's records into one frame, so a duplicate can't fail here.
        // The checks see the assembled frames, after the reader has merged and trimmed the turns,
        // not the raw records: a value the assembler drops is not refused.
        framesByTickId = try ReevaluationRecordContentCheck.checkedIndex(contents.frames, maxReplayTicks: maxReplayTicks)
        maxTickId = contents.frames.map(\.tickId).max() ?? -1
        completeness = contents.completeness
        holdsNonNFCText = contents.holdsNonNFCText
    }

    public func getMetadata() async throws -> ReevaluationRecordMetadata { metadata }

    public func getActions(for tickId: Int64) async throws -> [ReevaluationRecordedAction] {
        framesByTickId[tickId]?.actions ?? []
    }

    public func getClientEvents(for tickId: Int64) async throws -> [ReevaluationRecordedClientEvent] {
        framesByTickId[tickId]?.clientEvents ?? []
    }

    public func getServerInputs(for tickId: Int64) async throws -> [ReevaluationRecordedServerInput] {
        framesByTickId[tickId]?.serverInputs ?? []
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

    public func getPasses(for tickId: Int64) async throws -> [ReevaluationRecordedPass] {
        framesByTickId[tickId]?.passes ?? []
    }

    public func getRejected(for tickId: Int64) async throws -> [Int64] {
        framesByTickId[tickId]?.rejected ?? []
    }

    public func getLandFailure() async throws -> (tickId: Int64, failure: LandFailure)? {
        frames.first { $0.landFailure != nil }.flatMap { frame in frame.landFailure.map { (frame.tickId, $0) } }
    }

    public func getSyncStream() async throws -> [ReevaluationSyncStreamEntry] {
        ReevaluationSyncStreamEntry.stream(of: frames)
    }

    public func getInitializeRecord() async throws -> ReevaluationRecordedInitialize? {
        framesByTickId[0]?.initialize
    }

    public func getRecordCompleteness() async throws -> ReevaluationRecordCompleteness { completeness }

    public func getHoldsNonNFCText() async throws -> Bool { holdsNonNFCText }

    /// The frames, as the 2.6 JSON view holds them (`ReevaluationRecordFile.jsonView`).
    public func getAllFrames() -> [ReevaluationTickFrame] { frames }
}

/// Opens a record file of any supported format.
public enum ReevaluationRecordFile {
    /// The most steps a replay run may take unless a caller says otherwise: the record's last
    /// tick + 1 (#728). A run steps every tick from 0 to the last one (a tickless land's passes
    /// are steps inside a tick, so they aren't counted). 1,000,000 ticks is about 13.9 hours at
    /// 50 ms ticks. A land that stays alive longer needs a raised limit.
    public static let defaultMaxReplayTicks: Int64 = 1_000_000

    /// A 3.x log (`SSTR` magic) opens `ReevaluationRecordLogSource`; anything else the 2.x
    /// `JSONReevaluationSource`, which rejects records older than `minimumSupported`. A record
    /// whose last tick + 1 is past `maxReplayTicks` (at least 1) is refused with `replayTooLong`.
    public static func openSource(
        filePath: String,
        maxReplayTicks: Int64 = ReevaluationRecordFile.defaultMaxReplayTicks
    ) throws -> any ReevaluationSource {
        precondition(maxReplayTicks >= 1, "maxReplayTicks must be at least 1")
        return try openSource(data: Data(contentsOf: URL(fileURLWithPath: filePath)), maxReplayTicks: maxReplayTicks)
    }

    public static func openSource(
        data: Data,
        maxReplayTicks: Int64 = ReevaluationRecordFile.defaultMaxReplayTicks
    ) throws -> any ReevaluationSource {
        precondition(maxReplayTicks >= 1, "maxReplayTicks must be at least 1")
        if ReevaluationRecordLog.hasMagic(data) {
            return try ReevaluationRecordLogSource(bytes: Array(data), maxReplayTicks: maxReplayTicks)
        }
        return try JSONReevaluationSource(data: data, maxReplayTicks: maxReplayTicks)
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
