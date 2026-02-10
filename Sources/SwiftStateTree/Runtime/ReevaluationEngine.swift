import Foundation
import Logging

/// A small helper for running deterministic re-evaluation from a recorded timeline.
///
/// This is intentionally generic and is meant to be used by demo-specific runners
/// (e.g., `Examples/Demo` and `Examples/GameDemo`) that can import their own land definitions.
public enum ReevaluationEngine {
    private actor CapturingSink: ReevaluationSink {
        private var eventsByTick: [Int64: [ReevaluationRecordedServerEvent]] = [:]
        private let downstream: (any ReevaluationSink)?

        init(downstream: (any ReevaluationSink)?) { self.downstream = downstream }

        func onEmittedServerEvents(tickId: Int64, events: [ReevaluationRecordedServerEvent]) async {
            eventsByTick[tickId, default: []].append(contentsOf: events)
            if let downstream { await downstream.onEmittedServerEvents(tickId: tickId, events: events) }
        }

        func takeEmittedEvents(for tickId: Int64) -> [ReevaluationRecordedServerEvent] {
            let events = eventsByTick.removeValue(forKey: tickId) ?? []
            return events.sorted { $0.sequence < $1.sequence }
        }
    }

    public struct RunResult: Sendable {
        public let maxTickId: Int64
        public let tickHashes: [Int64: String]
        public let recordedStateHashes: [Int64: String]
    }
    
    /// Run a deterministic re-evaluation from a JSON record file.
    public static func run<State: StateNodeProtocol>(
        definition: LandDefinition<State>,
        initialState: State,
        recordFilePath: String,
        services: LandServices = LandServices(),
        sink: (any ReevaluationSink)? = nil,
        exportJsonlPath: String? = nil,
        includeStateHashInExport: Bool = true,
        logger: Logger? = nil
    ) async throws -> RunResult {
        let source = try JSONReevaluationSource(filePath: recordFilePath)
        let metadata = try await source.getMetadata()
        let maxTickId = try await source.getMaxTickId()
        let capturingSink = CapturingSink(downstream: sink)

        // Ensure RNG seed matches the recorded run (critical for deterministic re-evaluation).
        var resolvedServices = services
        let expectedSeedFromLandID = DeterministicSeed.fromLandID(metadata.landID)
        if let recordedSeed = metadata.rngSeed, recordedSeed != expectedSeedFromLandID {
            logger?.warning(
                "Recorded rngSeed does not match landID-derived seed; using landID-derived seed for deterministic re-evaluation.",
                metadata: [
                    "landID": .string(metadata.landID),
                    "recordedSeed": .stringConvertible(recordedSeed),
                    "expectedSeed": .stringConvertible(expectedSeedFromLandID),
                ]
            )
        }
        resolvedServices.register(
            DeterministicRngService(seed: expectedSeedFromLandID),
            as: DeterministicRngService.self
        )
        
        let keeper = LandKeeper<State>(
            definition: definition,
            initialState: initialState,
            mode: .reevaluation,
            reevaluationSource: source,
            reevaluationSink: capturingSink,
            services: resolvedServices,
            autoStartLoops: false,
            logger: logger
        )
        await keeper.setLandID(metadata.landID)
        
        let syncEngine = SyncEngine()
        let snapshotEncoder = JSONEncoder()
        snapshotEncoder.outputFormatting = [.sortedKeys]
        
        let exporter: ReevaluationJsonlExporter? = try exportJsonlPath.map { path in
            try ReevaluationJsonlExporter(outputPath: path, overwrite: true)
        }
        
        var hashes: [Int64: String] = [:]
        var recordedHashes: [Int64: String] = [:]
        if maxTickId >= 0 {
            for tickId in 0...maxTickId {
                await keeper.stepTickOnce()
                let state = await keeper.currentState()
                
                let snapshot = try syncEngine.snapshot(from: state, mode: .all)
                let stateHash: String
                if let data = try? snapshotEncoder.encode(snapshot) {
                    stateHash = DeterministicHash.toHex64(DeterministicHash.fnv1a64(data))
                } else {
                    stateHash = "error"
                }
                hashes[tickId] = stateHash

                if let recorded = try await source.getStateHash(for: tickId) {
                    recordedHashes[tickId] = recorded
                }
                
                if let exporter {
                    let sortedEvents = await capturingSink.takeEmittedEvents(for: tickId)
                    try await exporter.writeTick(
                        tickId: tickId,
                        stateSnapshot: snapshot,
                        stateHash: includeStateHashInExport ? stateHash : nil,
                        serverEvents: sortedEvents
                    )
                }
            }
        }
        
        if let exporter {
            try await exporter.close()
        }
        
        return RunResult(maxTickId: maxTickId, tickHashes: hashes, recordedStateHashes: recordedHashes)
    }
    
    /// Calculate a deterministic hash of the full state snapshot.
    public static func calculateStateHash<State: StateNodeProtocol>(_ state: State) -> String {
        let syncEngine = SyncEngine()
        let snapshot: StateSnapshot
        do {
            snapshot = try syncEngine.snapshot(from: state, mode: .all)
        } catch {
            return "error"
        }
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else {
            return "error"
        }
        return DeterministicHash.toHex64(DeterministicHash.fnv1a64(data))
    }
}

