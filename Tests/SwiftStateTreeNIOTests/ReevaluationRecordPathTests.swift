// Tests/SwiftStateTreeNIOTests/ReevaluationRecordPathTests.swift
//
// The record path a replay start returns is the path the client sent (#281), with only `.` and
// `..` removed, while the check that it lies within the records directory still standardizes
// both sides. On macOS `standardizedFileURL` drops the `/private` of `/private/tmp` and
// `/private/var`, so a path sent under `/private` used to come back spelled differently.

import Foundation
import Testing
@testable import SwiftStateTreeNIO
import SwiftStateTreeReevaluationMonitor

@Suite("Replay start record path (#281)")
struct ReevaluationRecordPathTests {
    /// A records directory with one record, under the temporary directory. On macOS the
    /// temporary directory is under `/var`, a symlink to `/private/var`: `privateSpelling` is the
    /// same directory spelled under `/private` when that spelling exists (macOS), else the plain one.
    struct Fixture {
        let base: String
        let records: String
        let record: String

        init(privateSpelling: Bool) throws {
            let tmp = FileManager.default.temporaryDirectory.standardizedFileURL.path
            let root = privateSpelling && FileManager.default.fileExists(atPath: "/private" + tmp) ? "/private" + tmp : tmp
            base = "\(root)/sst-record-path-\(UUID().uuidString.lowercased())"
            records = "\(base)/records"
            record = "\(records)/a.json"
            try FileManager.default.createDirectory(atPath: records, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: record, contents: Data("{}".utf8))
        }

        func remove() {
            try? FileManager.default.removeItem(atPath: base)
        }
    }

    @Test("An absolute path comes back as sent, also under /private on macOS")
    func absolutePathAsSent() throws {
        for privateSpelling in [true, false] {
            let f = try Fixture(privateSpelling: privateSpelling)
            defer { f.remove() }
            let resolved = resolveReevaluationRecordPath(rawPath: f.record, recordsDir: f.records, currentDirectory: f.base)
            #expect(resolved?.path == f.record, "private spelling: \(privateSpelling)")
            // The replay land reads the path back from its land ID's token and checks it against
            // the records directory, in either spelling.
            let token = Data(f.record.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            for recordsDir in [f.records, URL(fileURLWithPath: f.records).standardizedFileURL.path] {
                let descriptor = ReevaluationReplaySessionDescriptor.decode(instanceId: "id.\(token)", landType: "t-replay", recordsDir: recordsDir)
                #expect(descriptor?.recordFilePath == f.record, "records dir \(recordsDir)")
            }
        }
    }

    @Test("The records directory and the path may spell the same directory differently")
    func containmentIgnoresThePrivateSpelling() throws {
        let f = try Fixture(privateSpelling: true)
        defer { f.remove() }
        // The records directory without `/private`, the path with it (on macOS; the same on Linux).
        let plainRecords = URL(fileURLWithPath: f.records).standardizedFileURL.path
        let resolved = resolveReevaluationRecordPath(rawPath: f.record, recordsDir: plainRecords, currentDirectory: f.base)
        #expect(resolved?.path == f.record)
    }

    @Test("A relative path resolves against the records directory, in its spelling")
    func relativePath() throws {
        let f = try Fixture(privateSpelling: true)
        defer { f.remove() }
        #expect(resolveReevaluationRecordPath(rawPath: "a.json", recordsDir: f.records, currentDirectory: f.base)?.path == f.record)
        // Relative to the current directory first.
        #expect(resolveReevaluationRecordPath(rawPath: "records/a.json", recordsDir: f.records, currentDirectory: f.base)?.path == f.record)
        // A relative records directory, against the current directory.
        #expect(resolveReevaluationRecordPath(rawPath: "a.json", recordsDir: "records", currentDirectory: f.base)?.path == f.record)
    }

    @Test("Only . and .. are removed from the returned path")
    func dotSegmentsRemoved() throws {
        let f = try Fixture(privateSpelling: true)
        defer { f.remove() }
        let raw = "\(f.records)/./sub/../a.json"
        #expect(resolveReevaluationRecordPath(rawPath: raw, recordsDir: f.records, currentDirectory: f.base)?.path == f.record)
    }

    @Test("A path outside the records directory is refused")
    func outsideRefused() throws {
        let f = try Fixture(privateSpelling: true)
        defer { f.remove() }
        #expect(resolveReevaluationRecordPath(rawPath: "/etc/passwd", recordsDir: f.records, currentDirectory: f.base) == nil)
        #expect(resolveReevaluationRecordPath(rawPath: "\(f.records)/../outside.json", recordsDir: f.records, currentDirectory: f.base) == nil)
        #expect(resolveReevaluationRecordPath(rawPath: "../outside.json", recordsDir: f.records, currentDirectory: f.records) == nil)
        // A sibling whose name starts with the directory's.
        #expect(resolveReevaluationRecordPath(rawPath: "\(f.records)-other/a.json", recordsDir: f.records, currentDirectory: f.base) == nil)
    }
}
