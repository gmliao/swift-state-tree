import Foundation
import Logging
import Testing
@testable import SwiftStateTree

/// Write errors in the file and stream sinks surface as errors, not as a terminated process
/// (#263). A handle opened read-only makes every write fail (EBADF) without touching another
/// test's descriptors; the non-throwing `FileHandle.write(_:)` would end the test process.
@Suite("Failing writes")
struct FailingWriteTests {
    private func readOnlyHandle() throws -> FileHandle {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("failing-write-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try FileHandle(forReadingFrom: url)
    }

    @Test("The stream writer throws on a failed write")
    func streamWriterThrows() throws {
        let handle = try readOnlyHandle()
        let write = ColoredLogHandler.streamWriter(standardOutput: handle, standardError: handle)
        #expect(throws: (any Error).self) { try write(Data("line\n".utf8), .info) }
        #expect(throws: (any Error).self) { try write(Data("line\n".utf8), .error) }
    }

    @Test("The stream writer sends errors to standard error and the rest to standard output")
    func streamWriterRoutesByLevel() throws {
        let out = Pipe()
        let err = Pipe()
        let write = ColoredLogHandler.streamWriter(
            standardOutput: out.fileHandleForWriting,
            standardError: err.fileHandleForWriting
        )
        try write(Data("info\n".utf8), .warning)
        try write(Data("error\n".utf8), .error)
        try out.fileHandleForWriting.close()
        try err.fileHandleForWriting.close()
        #expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "info\n")
        #expect(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "error\n")
    }

    @Test("The log handler drops a line whose write fails and keeps logging")
    func logHandlerDropsFailedLine() throws {
        let attempts = Attempts()
        let handler = ColoredLogHandler(
            loggerIdentifier: "test",
            logLevel: .info,
            useColors: false,
            writeLine: { data, _ in
                attempts.add(String(decoding: data, as: UTF8.self))
                struct Full: Error {}
                throw Full()
            }
        )
        let logger = Logger(label: "test") { _ in handler }
        logger.info("first")
        logger.error("second")
        let lines = attempts.lines
        #expect(lines.count == 2)
        #expect(lines.first?.hasSuffix("first\n") == true)
        #expect(lines.last?.hasSuffix("second\n") == true)
    }

    @Test("The re-evaluation exporter throws an export write error naming the tick")
    func exporterThrows() async throws {
        let exporter = ReevaluationJsonlExporter(handle: try readOnlyHandle(), path: "read-only")
        let error = await #expect(throws: ReevaluationExportWriteError.self) {
            try await exporter.writeTick(tickId: 7, stateSnapshot: StateSnapshot(values: [:]), stateHash: nil, serverEvents: [])
        }
        #expect(error?.tickId == 7)
        #expect(error?.path == "read-only")
        #expect(error?.description.hasPrefix("export write error") == true)
    }

    @Test("A standard error diagnostic whose write fails is dropped")
    func standardErrorDiagnosticDropped() throws {
        #expect(writeStandardErrorDiagnostic("lost\n", to: try readOnlyHandle()) == false)
        let pipe = Pipe()
        #expect(writeStandardErrorDiagnostic("kept\n", to: pipe.fileHandleForWriting))
        try pipe.fileHandleForWriting.close()
        #expect(String(decoding: try pipe.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self) == "kept\n")
    }

    /// A full device (ENOSPC), where one exists (Linux): the error a full disk gives.
    @Test(
        "Writes to a full device fail without ending the process",
        .enabled(if: FileManager.default.fileExists(atPath: "/dev/full"))
    )
    func fullDevice() async throws {
        func fullHandle() throws -> FileHandle {
            try #require(FileHandle(forWritingAtPath: "/dev/full"))
        }
        let write = ColoredLogHandler.streamWriter(standardOutput: try fullHandle(), standardError: try fullHandle())
        #expect(throws: (any Error).self) { try write(Data("line\n".utf8), .info) }
        #expect(writeStandardErrorDiagnostic("lost\n", to: try fullHandle()) == false)
        let exporter = ReevaluationJsonlExporter(handle: try fullHandle(), path: "/dev/full")
        await #expect(throws: ReevaluationExportWriteError.self) {
            try await exporter.writeTick(tickId: 1, stateSnapshot: StateSnapshot(values: [:]), stateHash: nil, serverEvents: [])
        }
    }

    @Test("The re-evaluation exporter writes each tick as one line")
    func exporterWritesLines() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-\(UUID().uuidString).jsonl")
        let exporter = try ReevaluationJsonlExporter(outputPath: url.path)
        try await exporter.writeTick(tickId: 1, stateSnapshot: StateSnapshot(values: [:]), stateHash: "h", serverEvents: [])
        try await exporter.writeTick(tickId: 2, stateSnapshot: StateSnapshot(values: [:]), stateHash: nil, serverEvents: [])
        try await exporter.close()
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 3)
        #expect(lines[0].contains("\"tickId\":1"))
        #expect(lines[1].contains("\"tickId\":2"))
        #expect(lines[2].isEmpty)
    }
}

private final class Attempts: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func add(_ line: String) {
        lock.lock()
        stored.append(line)
        lock.unlock()
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
