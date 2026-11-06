// Sources/ServerLoadTest/StreamDump.swift
//
// Writes each session's received frames to a file of its own (`--stream-dir`), for offline
// sizing of the sync stream (deep-research/recomputation-cost). Each frame is a 4-byte
// big-endian length, then the frame's bytes, as the server encoded it.

import Foundation

actor StreamDump {
    private let directory: URL
    private var files: [String: FileHandle] = [:]
    private(set) var failures = 0

    init(directory: String) throws {
        self.directory = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    /// Appends `data` to the stream file `name` (created on first use).
    func append(_ data: Data, to name: String) {
        do {
            let handle = try files[name] ?? open(name)
            var length = UInt32(data.count).bigEndian
            try handle.write(contentsOf: Data(bytes: &length, count: 4))
            try handle.write(contentsOf: data)
        } catch {
            failures += 1
        }
    }

    private func open(_ name: String) throws -> FileHandle {
        let url = directory.appendingPathComponent("\(name).bin")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        files[name] = handle
        return handle
    }

    /// Closes every file; returns how many sessions were written.
    func closeAll() -> Int {
        for handle in files.values { try? handle.close() }
        let count = files.count
        files.removeAll()
        return count
    }
}
