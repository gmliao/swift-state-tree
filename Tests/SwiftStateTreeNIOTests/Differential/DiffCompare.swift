// Tests/SwiftStateTreeNIOTests/Differential/DiffCompare.swift
//
// The comparison of two runs (#555, plan §5.7 and rev 10's "Comparing the record"): frames per
// connection, in order, byte for byte; each close; the record's bytes, and when they differ,
// each differing field path of the decoded records as well. Every differing frame is its own
// difference, naming the checkpoint, the connection, the frame's index, both frames decoded and,
// when bytes are compared, both frames' digests: an expected difference covers exactly one frame
// with exactly those bytes, never the frames after it.

#if DEBUG
import Foundation

/// One difference between two runs, on one channel.
struct DiffDifference: Equatable, Sendable, CustomStringConvertible {
    enum Channel: String, Sendable {
        case frames
        case close
        case record
        case note
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
            for index in differingFrames(a.frames, b.frames, checkBytes: checkBytes) {
                let left = index < a.frames.count ? a.frames[index] : nil
                let right = index < b.frames.count ? b.frames[index] : nil
                let text = { (frame: DiffFrame?) in frame.map { DiffValue.canonicalText($0.decoded) } ?? "<none>" }
                var detail = "frame \(index) of \(a.frames.count) vs \(b.frames.count): expected \(text(left)), got \(text(right))"
                if checkBytes {
                    detail += " (bytes \(digest(left?.bytes)) vs \(digest(right?.bytes)))"
                }
                found.append(.init(checkpoint: checkpoint, channel: .frames, place: name, detail: detail))
            }
            if a.close != b.close {
                found.append(.init(checkpoint: checkpoint, channel: .close, place: name,
                                   detail: "expected \(describe(a.close)), got \(describe(b.close))"))
            }
        }
        let left = expected.notes ?? [:], right = actual.notes ?? [:]
        for name in Set(left.keys).union(right.keys).sorted() where left[name] != right[name] {
            let text = { (value: DiffValue?) in value.map { DiffValue.canonicalText($0) } ?? "<none>" }
            found.append(.init(checkpoint: checkpoint, channel: .note, place: name,
                               detail: "expected \(text(left[name])), got \(text(right[name]))"))
        }
        return found
    }

    /// Every index where the two streams differ, a frame only one of them has included.
    private static func differingFrames(_ a: [DiffFrame], _ b: [DiffFrame], checkBytes: Bool) -> [Int] {
        (0..<max(a.count, b.count)).filter { index in
            guard index < a.count, index < b.count else { return true }
            return checkBytes ? a[index].bytes != b[index].bytes : a[index].decoded != b[index].decoded
        }
    }

    /// The bytes' 64-bit FNV-1a digest in hex, `<none>` for a missing frame: it keys an expected
    /// difference to the exact bytes (a stable value across processes and platforms, unlike
    /// `hashValue`).
    static func digest(_ bytes: Data?) -> String {
        guard let bytes else { return "<none>" }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return "fnv64:" + String(repeating: "0", count: 16 - hex.count) + hex
    }

    private static func describe(_ close: DiffClose?) -> String {
        close.map { "\($0.code) \"\($0.reason)\"" } ?? "no close"
    }

    /// The record: its bytes first; when they differ, a `<bytes>` difference with both digests,
    /// and each differing field path beside it. The bytes difference is emitted even when fields
    /// differ, so an expected difference for a field can't cover another byte change: the
    /// branch lists the bytes difference too, with the exact digests.
    static func compareRecord(_ expected: DiffRecordCapture, _ actual: DiffRecordCapture, checkBytes: Bool) -> [DiffDifference] {
        var found: [DiffDifference] = []
        if checkBytes {
            if expected.bytes == actual.bytes { return [] }
            found.append(.init(checkpoint: "terminal", channel: .record, place: "<bytes>",
                               detail: "\(digest(expected.bytes)) vs \(digest(actual.bytes))"))
        }
        var paths: [(String, String)] = []
        walk(expected.decoded, actual.decoded, path: "", into: &paths)
        return found + paths.map { .init(checkpoint: "terminal", channel: .record, place: $0.0, detail: $0.1) }
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
