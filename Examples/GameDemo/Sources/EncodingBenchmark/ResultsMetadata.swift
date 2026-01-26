// Examples/GameDemo/Sources/EncodingBenchmark/ResultsMetadata.swift
//
// Results directory management and metadata collection.

import Foundation

// MARK: - Results Directory

enum ResultsManager {
    /// Get the results directory path (now at GameDemo/results/encoding-benchmark/)
    static func getResultsDirectory() -> URL {
        let fileManager = FileManager.default
        var currentDir = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        
        // Look for GameDemo directory (where Package.swift is)
        var gameDemoDir: URL?
        for _ in 0..<10 {
            if fileManager.fileExists(atPath: currentDir.appendingPathComponent("Package.swift").path) {
                gameDemoDir = currentDir
                break
            }
            let parent = currentDir.deletingLastPathComponent()
            if parent.path == currentDir.path {
                break
            }
            currentDir = parent
        }
        
        // Fallback: use current directory
        if gameDemoDir == nil {
            gameDemoDir = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        }
        
        let resultsDir = gameDemoDir!.appendingPathComponent("results/encoding-benchmark", isDirectory: true)
        try? fileManager.createDirectory(at: resultsDir, withIntermediateDirectories: true)
        
        return resultsDir
    }

    // MARK: - Results Metadata

    static func runCommandCaptureStdout(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    static func runCommandCaptureStdout(_ arguments: [String]) -> String? {
        guard let executable = arguments.first else { return nil }
        // Resolve common executables via PATH by trying /usr/bin and /bin first, then raw.
        let candidates = ["/usr/bin/\(executable)", "/bin/\(executable)", executable]
        for candidate in candidates {
            let output = Self.runCommandCaptureStdout(candidate, Array(arguments.dropFirst()))
            if let output, !output.isEmpty {
                return output
            }
        }
        return nil
    }

    static func readTextFile(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    static func detectWSL() -> Bool {
        if ProcessInfo.processInfo.environment["WSL_INTEROP"] != nil { return true }
        if let osrelease = Self.readTextFile("/proc/sys/kernel/osrelease"),
           osrelease.lowercased().contains("microsoft") { return true }
        return false
    }

    static func detectContainer() -> Bool {
        if FileManager.default.fileExists(atPath: "/.dockerenv") { return true }
        if let cgroup = Self.readTextFile("/proc/1/cgroup")?.lowercased() {
            if cgroup.contains("docker") || cgroup.contains("containerd") || cgroup.contains("kubepods") { return true }
        }
        return false
    }

    static func cpuModelName() -> String? {
        guard let cpuinfo = Self.readTextFile("/proc/cpuinfo") else { return nil }
        for line in cpuinfo.split(separator: "\n") {
            if line.lowercased().hasPrefix("model name") {
                return line.split(separator: ":", maxSplits: 1).last?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    static func cpuPhysicalCoresHint() -> Int? {
        // Best-effort on Linux: use the first 'cpu cores' entry.
        guard let cpuinfo = Self.readTextFile("/proc/cpuinfo") else { return nil }
        for line in cpuinfo.split(separator: "\n") {
            if line.lowercased().hasPrefix("cpu cores") {
                if let value = line.split(separator: ":", maxSplits: 1).last?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   let cores = Int(value)
                {
                    return cores
                }
            }
        }
        return nil
    }

    static func unameInfo() -> [String: String] {
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
            "machine": toString(uts.machine)
        ]
    }

    static func buildConfigurationName() -> String {
    #if DEBUG
        return "debug"
    #else
        return "release"
    #endif
    }

    static func collectResultsMetadata(benchmarkConfig: [String: Any]) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let uname = Self.unameInfo()
        let env = ProcessInfo.processInfo.environment

        // Minimal, safe allowlist (avoid secrets).
        let allowEnvKeys = [
            "TRANSPORT_ENCODING",
            "WSL_DISTRO_NAME",
            "WSL_INTEROP"
        ]
        var selectedEnv: [String: String] = [:]
        for key in allowEnvKeys {
            if let value = env[key] {
                selectedEnv[key] = value
            }
        }

        let cpuLogical = ProcessInfo.processInfo.processorCount
        let cpuActive = ProcessInfo.processInfo.activeProcessorCount
        let memoryMB = Int(ProcessInfo.processInfo.physicalMemory / 1024 / 1024)

        let swiftVersion = Self.runCommandCaptureStdout(["swift", "--version"])
            .flatMap { $0.split(separator: "\n").first.map(String.init) }

        let gitCommit = Self.runCommandCaptureStdout(["git", "rev-parse", "HEAD"])
        let gitBranch = Self.runCommandCaptureStdout(["git", "rev-parse", "--abbrev-ref", "HEAD"])

        return [
            "timestampUTC": iso.string(from: Date()),
            "commandLine": CommandLine.arguments,
            "build": [
                "configuration": Self.buildConfigurationName(),
                "swiftVersion": swiftVersion as Any
            ],
            "git": [
                "commit": gitCommit as Any,
                "branch": gitBranch as Any
            ],
            "environment": [
                "osName": uname["sysname"] as Any,
                "kernelVersion": uname["release"] as Any,
                "arch": uname["machine"] as Any,
                "cpuModel": Self.cpuModelName() as Any,
                "cpuPhysicalCores": Self.cpuPhysicalCoresHint() as Any,
                "cpuLogicalCores": cpuLogical,
                "cpuActiveLogicalCores": cpuActive,
                "memoryTotalMB": memoryMB,
                "wsl": Self.detectWSL(),
                "container": Self.detectContainer()
            ],
            "env": selectedEnv,
            "benchmarkConfig": benchmarkConfig
        ]
    }

    /// Save benchmark results to JSON file as an envelope: { metadata, results }
    static func saveResultsToJSON(_ results: Any, filename: String, benchmarkConfig: [String: Any] = [:]) {
        let resultsDir = Self.getResultsDirectory()
        let fileURL = resultsDir.appendingPathComponent(filename)
        
        do {
            let metadata = Self.collectResultsMetadata(benchmarkConfig: benchmarkConfig)
            let envelope: [String: Any] = [
                "metadata": metadata,
                "results": results
            ]
            let jsonData = try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys])
            try jsonData.write(to: fileURL)
            print("")
            print("Results saved to: \(fileURL.path)")
        } catch {
            print("Failed to save results to JSON: \(error)")
        }
    }
}
