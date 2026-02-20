// Sources/SwiftStateTreeReevaluationMonitor/ReevaluationReplaySessionDescriptor.swift
//
// Replay session descriptor for same-land reevaluation: encode from admin replay start
// response, decode from land instanceId for runtime reevaluationSource resolution.

import Foundation
import SwiftStateTree

/// Descriptor for a replay session that can be encoded from admin replay start response
/// and decoded from land instanceId when a client connects.
///
/// Used by the runtime to resolve `reevaluationSource` for same-land replay sessions.
public struct ReevaluationReplaySessionDescriptor: Sendable {
    public let recordFilePath: String
    public let landType: String
    public let webSocketPath: String
    public let replayLandID: String

    public init(
        recordFilePath: String,
        landType: String,
        webSocketPath: String,
        replayLandID: String
    ) {
        self.recordFilePath = recordFilePath
        self.landType = landType
        self.webSocketPath = webSocketPath
        self.replayLandID = replayLandID
    }

    /// Build descriptor from admin replay start response data.
    /// Returns nil if required fields are missing.
    public static func encode(from responseData: [String: Any]) -> ReevaluationReplaySessionDescriptor? {
        guard let recordFilePath = responseData["recordFilePath"] as? String,
              let landType = responseData["landType"] as? String,
              let webSocketPath = responseData["webSocketPath"] as? String,
              let replayLandID = responseData["replayLandID"] as? String,
              !recordFilePath.isEmpty,
              !landType.isEmpty,
              !webSocketPath.isEmpty,
              !replayLandID.isEmpty
        else {
            return nil
        }
        return ReevaluationReplaySessionDescriptor(
            recordFilePath: recordFilePath,
            landType: landType,
            webSocketPath: webSocketPath,
            replayLandID: replayLandID
        )
    }

    /// Decode descriptor from land instanceId when a client connects.
    /// The instanceId format is "uuid.pathToken" where pathToken is base64url(recordFilePath).
    /// Returns nil if token is invalid, path contains traversal, or path is outside recordsDir.
    public static func decode(
        instanceId: String,
        landType: String,
        recordsDir: String
    ) -> ReevaluationReplaySessionDescriptor? {
        let parts = instanceId.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty else {
            return nil
        }
        let pathToken = String(parts[1])

        let base64 = pathToken
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        let padded = remainder > 0 ? base64 + String(repeating: "=", count: 4 - remainder) : base64

        guard let data = Data(base64Encoded: padded),
              let recordFilePath = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        if recordFilePath.contains("..") {
            return nil
        }

        let recordsDirURL = URL(fileURLWithPath: recordsDir, isDirectory: true).standardizedFileURL
        let pathURL = URL(fileURLWithPath: recordFilePath).standardizedFileURL

        let recordsPath = recordsDirURL.path.hasSuffix("/") ? recordsDirURL.path : "\(recordsDirURL.path)/"
        guard pathURL.path == recordsDirURL.path || pathURL.path.hasPrefix(recordsPath) else {
            return nil
        }

        let webSocketPath = "/game/\(landType)"
        let replayLandID = "\(landType):\(instanceId)"

        return ReevaluationReplaySessionDescriptor(
            recordFilePath: recordFilePath,
            landType: landType,
            webSocketPath: webSocketPath,
            replayLandID: replayLandID
        )
    }
}
