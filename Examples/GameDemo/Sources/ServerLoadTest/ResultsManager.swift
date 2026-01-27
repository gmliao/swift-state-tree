// Sources/ServerLoadTest/ResultsManager.swift
//
// Results file handling and metadata collection.

import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

// MARK: - Build Configuration

func buildConfigurationName() -> String {
    #if DEBUG
        return "debug"
    #else
        return "release"
    #endif
}

// MARK: - Command Execution

func runCommandCaptureStdout(_ arguments: [String]) -> String? {
    guard let executable = arguments.first else { return nil }
    let candidates = ["/usr/bin/\(executable)", "/bin/\(executable)", executable]
    for candidate in candidates {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: candidate)
        process.arguments = Array(arguments.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { continue }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
                return output
            }
        } catch {
            continue
        }
    }
    return nil
}

// MARK: - System Info

func unameInfo() -> [String: String] {
    var uts = utsname()
    uname(&uts)

    func toString(_ value: Any) -> String {
        let mirror = Mirror(reflecting: value)
        let bytes = mirror.children.compactMap { $0.value as? Int8 }
        let data = Data(bytes.map { UInt8(bitPattern: $0) })
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) ?? ""
    }

    return [
        "sysname": toString(uts.sysname),
        "nodename": toString(uts.nodename),
        "release": toString(uts.release),
        "version": toString(uts.version),
        "machine": toString(uts.machine),
    ]
}

// MARK: - Results Directory

func getResultsDirectory() -> URL {
    let fileManager = FileManager.default
    var currentDir = URL(fileURLWithPath: fileManager.currentDirectoryPath)

    var gameDemoDir: URL?
    for _ in 0 ..< 10 {
        if fileManager.fileExists(atPath: currentDir.appendingPathComponent("Package.swift").path) {
            gameDemoDir = currentDir
            break
        }
        let parent = currentDir.deletingLastPathComponent()
        if parent.path == currentDir.path { break }
        currentDir = parent
    }

    if gameDemoDir == nil {
        let sourceFile = #file
        let sourceURL = URL(fileURLWithPath: sourceFile)
        gameDemoDir = sourceURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    let resultsDir = gameDemoDir!.appendingPathComponent("results/server-loadtest", isDirectory: true)
    try? fileManager.createDirectory(at: resultsDir, withIntermediateDirectories: true)
    return resultsDir
}

// MARK: - Metadata Collection

func collectResultsMetadata(loadTestConfig: [String: Any]) -> [String: Any] {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    let uname = unameInfo()
    let cpuLogical = ProcessInfo.processInfo.processorCount
    let cpuActive = ProcessInfo.processInfo.activeProcessorCount
    let memoryMB = Int(ProcessInfo.processInfo.physicalMemory / 1024 / 1024)

    let swiftVersion = runCommandCaptureStdout(["swift", "--version"])
        .flatMap { $0.split(separator: "\n").first.map(String.init) }

    let gitCommit = runCommandCaptureStdout(["git", "rev-parse", "HEAD"])
    let gitBranch = runCommandCaptureStdout(["git", "rev-parse", "--abbrev-ref", "HEAD"])

    return [
        "timestampUTC": iso.string(from: Date()),
        "commandLine": CommandLine.arguments,
        "build": [
            "configuration": buildConfigurationName(),
            "swiftVersion": swiftVersion as Any,
        ],
        "git": [
            "commit": gitCommit as Any,
            "branch": gitBranch as Any,
        ],
        "environment": [
            "osName": uname["sysname"] as Any,
            "kernelVersion": uname["release"] as Any,
            "arch": uname["machine"] as Any,
            "cpuLogicalCores": cpuLogical,
            "cpuActiveLogicalCores": cpuActive,
            "memoryTotalMB": memoryMB,
        ],
        "loadTestConfig": loadTestConfig,
    ]
}

// MARK: - Save Results

func saveResultsToJSON(_ results: Any, filename: String, loadTestConfig: [String: Any]) {
    let resultsDir = getResultsDirectory()
    let fileURL = resultsDir.appendingPathComponent(filename)

    do {
        let metadata = collectResultsMetadata(loadTestConfig: loadTestConfig)
        let envelope: [String: Any] = [
            "metadata": metadata,
            "results": results,
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys])
        try jsonData.write(to: fileURL)
        print("")
        print("Results saved to: \(fileURL.path)")
    } catch {
        print("Failed to save results to JSON: \(error)")
    }
}
