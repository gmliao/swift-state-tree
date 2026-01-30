// Sources/ServerLoadTest/DebugLog.swift
// Agent debug instrumentation - NDJSON to .cursor/debug.log

import Foundation

// #region agent log
let _debugLogPath = "/Users/guanmingliao/Documents/GitHub/swift-state-tree/.cursor/debug.log"
func _debugLog(location: String, message: String, data: [String: Any] = [:], hypothesisId: String) {
    let payload: [String: Any] = [
        "location": location, "message": message, "data": data,
        "timestamp": Int(Date().timeIntervalSince1970 * 1000),
        "sessionId": "debug-session", "hypothesisId": hypothesisId
    ]
    guard let json = try? JSONSerialization.data(withJSONObject: payload),
          let line = String(data: json, encoding: .utf8) else { return }
    let lineWithNewline = line + "\n"
    if !FileManager.default.fileExists(atPath: _debugLogPath) {
        FileManager.default.createFile(atPath: _debugLogPath, contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: _debugLogPath)) else { return }
    defer { try? handle.close() }
    handle.seekToEndOfFile()
    handle.write(lineWithNewline.data(using: .utf8)!)
}
// #endregion
