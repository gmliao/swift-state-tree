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
    /// How long `saveOnShutdown` waits for the keeper's recorder submissions.
    public static let shutdownDrainDeadline: Duration = .seconds(5)

    /// Save reevaluation record to file system.
    ///
    /// - Parameters:
    ///   - recorder: The ReevaluationRecorder instance
    ///   - recordsDir: Optional custom directory path. If nil, uses `REEVALUATION_RECORDS_DIR` environment variable or defaults to `./reevaluation-records`
    ///   - filenamePrefix: Prefix for the generated filename. Defaults to "reevaluation"
    ///   - pendingSubmissions: Submissions not yet recorded (the drain timed out); the record is
    ///     then closed as incomplete.
    /// - Returns: The saved file's path.
    @discardableResult
    public static func save(
        recorder: ReevaluationRecorder,
        recordsDir: String? = nil,
        filenamePrefix: String = "reevaluation",
        pendingSubmissions: Int = 0
    ) async throws -> String {
        // Determine records directory
        let dir = recordsDir ?? ReevaluationEnvConfig.fromEnvironment().recordsDir

        // Create directory if it doesn't exist
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: dir) {
            try fileManager.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true
            )
        }

        // Generate filename: {prefix}-{timestamp}-{random}.sstr
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let random = UUID().uuidString.prefix(8)
        let filename = "\(filenamePrefix)-\(timestamp)-\(random).sstr"
        let filePath = "\(dir)/\(filename)"

        try await recorder.save(to: filePath, pendingSubmissions: pendingSubmissions)
        return filePath
    }

    /// Save reevaluation record to file system using LandContext.
    ///
    /// This helper attempts to retrieve the recorder from LandContext services. It first waits
    /// for the keeper's recorder submissions (at most `shutdownDrainDeadline`), outside any
    /// keeper turn; on the deadline it saves what was recorded, marked incomplete, and logs the
    /// pending count.
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

        let pending = await service.submissions.drain(within: shutdownDrainDeadline)
        if pending > 0 {
            ctx.logger.warning(
                "Reevaluation record saved incomplete: submissions still pending after the shutdown deadline",
                metadata: ["landID": .string(ctx.landID), "pending": .stringConvertible(pending)]
            )
        }
        try await save(
            recorder: service.recorder,
            recordsDir: recordsDir,
            filenamePrefix: filenamePrefix,
            pendingSubmissions: pending
        )
    }
}
