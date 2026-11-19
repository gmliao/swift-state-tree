// Tests/SwiftStateTreeNIOTests/Differential/DiffCompare.swift
//
// The comparison of two runs (#555, plan §5.7 and rev 10's "Comparing the record"): frames per
// connection, in order, byte for byte; each close; the record's bytes, and when they differ,
// each differing field path of the decoded records. A report names the checkpoint, the
// connection and the index of the first differing frame, with both frames decoded.

#if DEBUG
import Foundation

/// One difference between two runs, on one channel.
struct DiffDifference: Equatable, Sendable, CustomStringConvertible {
    enum Channel: String, Sendable {
        case frames
        case close
        case record
    }

    let checkpoint: String
    let channel: Channel
    /// The connection attempt, or the record's field path.
    let place: String
    let detail: String

    var description: String { "\(checkpoint) \(channel.rawValue) \(place): \(detail)" }
}

enum DiffCompare {
    /// Every difference between `expected` (the golden) and `actual`, `checkBytes` false when the
    /// two were recorded on different platforms or toolchains (decoded views only).
    static func differences(_ expected: DiffRunResult, _ actual: DiffRunResult, checkBytes: Bool = true) -> [DiffDifference] {
        var found = compare(expected.live, actual.live, checkpoint: "live", checkBytes: checkBytes)
        found += compare(expected.terminal, actual.terminal, checkpoint: "terminal", checkBytes: checkBytes)
        found += compareRecord(expected.record, actual.record, checkBytes: checkBytes)
        return found
    }

    static func compare(_ expected: DiffCapture, _ actual: DiffCapture, checkpoint: String, checkBytes: Bool) -> [DiffDifference] {
        var found: [DiffDifference] = []
        for name in Set(expected.connections.keys).union(actual.connections.keys).sorted() {
            guard let a = expected.connections[name], let b = actual.connections[name] else {
                found.append(.init(checkpoint: checkpoint, channel: .frames, place: name,
                                   detail: expected.connections[name] == nil ? "an extra connection" : "a missing connection"))
                continue
            }
            if let index = firstDifference(a.frames, b.frames, checkBytes: checkBytes) {
                let left = index < a.frames.count ? DiffValue.canonicalText(a.frames[index].decoded) : "<none>"
                let right = index < b.frames.count ? DiffValue.canonicalText(b.frames[index].decoded) : "<none>"
                found.append(.init(
                    checkpoint: checkpoint, channel: .frames, place: name,
                    detail: "frame \(index) of \(a.frames.count) vs \(b.frames.count): expected \(left), got \(right)"
                ))
            }
            if a.close != b.close {
                found.append(.init(checkpoint: checkpoint, channel: .close, place: name,
                                   detail: "expected \(describe(a.close)), got \(describe(b.close))"))
            }
        }
        return found
    }

    private static func firstDifference(_ a: [DiffFrame], _ b: [DiffFrame], checkBytes: Bool) -> Int? {
        for index in 0..<max(a.count, b.count) {
            guard index < a.count, index < b.count else { return index }
            if checkBytes ? a[index].bytes != b[index].bytes : a[index].decoded != b[index].decoded {
                return index
            }
        }
        return nil
    }

    private static func describe(_ close: DiffClose?) -> String {
        close.map { "\($0.code) \"\($0.reason)\"" } ?? "no close"
    }

    /// The record: its bytes first; when they differ, each differing field path. Bytes that
    /// differ while no path differs fail too: the record format is shared code.
    static func compareRecord(_ expected: DiffRecordCapture, _ actual: DiffRecordCapture, checkBytes: Bool) -> [DiffDifference] {
        if checkBytes, expected.bytes == actual.bytes { return [] }
        var paths: [(String, String)] = []
        walk(expected.decoded, actual.decoded, path: "", into: &paths)
        if paths.isEmpty {
            return checkBytes
                ? [.init(checkpoint: "terminal", channel: .record, place: "<bytes>", detail: "the bytes differ while no field differs")]
                : []
        }
        return paths.map { .init(checkpoint: "terminal", channel: .record, place: $0.0, detail: $0.1) }
    }

    /// The decoded records' differing paths: `a.b` for a field, `a[3]` for an element.
    static func walk(_ a: DiffValue, _ b: DiffValue, path: String, into found: inout [(String, String)]) {
        switch (a, b) {
        case (.object(let x), .object(let y)):
            for key in Set(x.keys).union(y.keys).sorted() {
                let child = path.isEmpty ? key : "\(path).\(key)"
                switch (x[key], y[key]) {
                case (let l?, let r?): walk(l, r, path: child, into: &found)
                case (nil, let r?): found.append((child, "absent, then \(DiffValue.canonicalText(r))"))
                case (let l?, nil): found.append((child, "\(DiffValue.canonicalText(l)), then absent"))
                default: break
                }
            }
        case (.array(let x), .array(let y)) where x.count == y.count:
            for index in x.indices { walk(x[index], y[index], path: "\(path)[\(index)]", into: &found) }
        default:
            if a != b { found.append((path, "\(DiffValue.canonicalText(a)), then \(DiffValue.canonicalText(b))")) }
        }
    }
}
#endif
