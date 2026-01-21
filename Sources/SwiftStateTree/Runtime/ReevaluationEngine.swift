import Foundation
import Logging

/// A small helper for running deterministic re-evaluation from a recorded timeline.
///
/// This is intentionally generic and is meant to be used by demo-specific runners
/// (e.g., `Examples/HummingbirdDemo` and `Examples/GameDemo`) that can import their own land definitions.
public enum ReevaluationEngine {
    public struct RunResult: Sendable {
        public let maxTickId: Int64
        public let tickHashes: [Int64: String]
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
        let maxTickId = try await source.getMaxTickId()
        
        let keeper = LandKeeper<State>(
            definition: definition,
            initialState: initialState,
            mode: .reevaluation,
            reevaluationSource: source,
            reevaluationSink: sink,
            services: services,
            autoStartLoops: false,
            logger: logger
        )
        
        let syncEngine = SyncEngine()
        let snapshotEncoder = JSONEncoder()
        snapshotEncoder.outputFormatting = [.sortedKeys]
        
        let exporter: ReevaluationJsonlExporter? = try exportJsonlPath.map { path in
            try ReevaluationJsonlExporter(outputPath: path, overwrite: true)
        }
        
        var hashes: [Int64: String] = [:]
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
                
                if let exporter {
                    let recordedServerEvents = (try? await source.getServerEvents(for: tickId)) ?? []
                    let sortedEvents = recordedServerEvents.sorted { $0.sequence < $1.sequence }
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
        
        return RunResult(maxTickId: maxTickId, tickHashes: hashes)
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

