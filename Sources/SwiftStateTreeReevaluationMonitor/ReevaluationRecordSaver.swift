import Foundation
import SwiftStateTree

/// Generic reevaluation record saver for any Land.
///
/// This utility provides a convenient way to save reevaluation records
/// when a Land shuts down. It can be used in any Land's `AfterFinalize` hook.
///
/// Example usage:
/// ```swift
/// AfterFinalize { (state: MyState, ctx: LandContext) async in
///     try? await ReevaluationRecordSaver.saveOnShutdown(ctx: ctx)
/// }
/// ```
public enum ReevaluationRecordSaver {
    /// Save reevaluation record to file system.
    ///
    /// - Parameters:
    ///   - recorder: The ReevaluationRecorder instance
    ///   - recordsDir: Optional custom directory path. If nil, uses `REEVALUATION_RECORDS_DIR` environment variable or defaults to `./reevaluation-records`
    ///   - filenamePrefix: Prefix for the generated filename. Defaults to "reevaluation"
    public static func save(
        recorder: ReevaluationRecorder,
        recordsDir: String? = nil,
        filenamePrefix: String = "reevaluation"
    ) async throws {
        // Determine records directory
        let dir = recordsDir
            ?? ProcessInfo.processInfo.environment["REEVALUATION_RECORDS_DIR"]
            ?? "./reevaluation-records"

        // Create directory if it doesn't exist
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: dir) {
            try fileManager.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true
            )
        }

        // Generate filename: {prefix}-{timestamp}-{random}.json
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let random = UUID().uuidString.prefix(8)
        let filename = "\(filenamePrefix)-\(timestamp)-\(random).json"
        let filePath = "\(dir)/\(filename)"

        // Save record
        try await recorder.save(to: filePath)
    }

    /// Save reevaluation record to file system using LandContext.
    ///
    /// This helper attempts to retrieve the recorder from LandContext services.
    ///
    /// - Parameters:
    ///   - ctx: The LandContext
    ///   - recordsDir: Optional custom directory path
    ///   - filenamePrefix: Prefix for the generated filename
    public static func saveOnShutdown(
        ctx: LandContext,
        recordsDir: String? = nil,
        filenamePrefix: String = "reevaluation"
    ) async throws {
        guard let service = ctx.services.get(ReevaluationRecorderService.self) else {
            ctx.logger.debug("Reevaluation recording disabled (ReevaluationRecorderService not registered); skip saving.")
            return
        }

        try await save(
            recorder: service.recorder,
            recordsDir: recordsDir,
            filenamePrefix: filenamePrefix
        )
    }
}
