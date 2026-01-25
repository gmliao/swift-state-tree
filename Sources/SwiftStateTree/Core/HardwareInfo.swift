import Foundation

/// Hardware information for re-evaluation record metadata.
/// Used to verify deterministic behavior across different CPU architectures.
public struct HardwareInfo: Codable, Sendable {
    /// CPU architecture (e.g., "x86_64", "arm64", "aarch64").
    public let cpuArchitecture: String
    
    /// Operating system name (e.g., "macOS", "Linux").
    public let osName: String
    
    /// Operating system version (e.g., "13.0", "Ubuntu 22.04").
    public let osVersion: String
    
    /// CPU model name (if available, e.g., "Apple M2", "AMD Ryzen 7 7600X").
    public let cpuModel: String?
    
    /// Number of CPU cores (if available).
    public let cpuCores: Int?
    
    /// Swift version used for recording (e.g., "6.0").
    public let swiftVersion: String?
    
    public init(
        cpuArchitecture: String,
        osName: String,
        osVersion: String,
        cpuModel: String? = nil,
        cpuCores: Int? = nil,
        swiftVersion: String? = nil
    ) {
        self.cpuArchitecture = cpuArchitecture
        self.osName = osName
        self.osVersion = osVersion
        self.cpuModel = cpuModel
        self.cpuCores = cpuCores
        self.swiftVersion = swiftVersion
    }
}

/// Utility for collecting hardware information at runtime.
public enum HardwareInfoCollector {
    /// Collect current hardware information.
    /// Returns hardware info with best-effort detection of CPU architecture, OS, and other details.
    public static func collect() -> HardwareInfo {
        // CPU Architecture
        var cpuArch = "unknown"
        #if arch(x86_64)
        cpuArch = "x86_64"
        #elseif arch(arm64) || arch(aarch64)
        cpuArch = "arm64"
        #elseif arch(i386)
        cpuArch = "i386"
        #elseif arch(arm)
        cpuArch = "arm"
        #endif
        
        // OS Information
        let processInfo = ProcessInfo.processInfo
        var osName = "unknown"
        var osVersion = "unknown"
        
        #if os(macOS)
        osName = "macOS"
        if let version = processInfo.operatingSystemVersionString.components(separatedBy: " ").last {
            osVersion = version
        }
        #elseif os(Linux)
        osName = "Linux"
        // Try to get Linux distribution info
        if let release = try? String(contentsOfFile: "/etc/os-release", encoding: .utf8) {
            for line in release.components(separatedBy: "\n") {
                if line.hasPrefix("PRETTY_NAME=") {
                    let value = String(line.dropFirst("PRETTY_NAME=".count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    osVersion = value
                    break
                }
            }
        }
        if osVersion == "unknown" {
            osVersion = "Linux"
        }
        #elseif os(Windows)
        osName = "Windows"
        osVersion = processInfo.operatingSystemVersionString
        #endif
        
        // CPU Model (platform-specific)
        var cpuModel: String? = nil
        var cpuCores: Int? = nil
        
        #if os(macOS)
        // macOS: Use sysctl
        if let brandString = getSysctlString("machdep.cpu.brand_string") {
            cpuModel = brandString
        }
        if let cores = getSysctlInt("hw.ncpu") {
            cpuCores = cores
        }
        #elseif os(Linux)
        // Linux: Read /proc/cpuinfo
        // Note: /proc/cpuinfo format varies by architecture:
        // - x86_64: uses "model name"
        // - ARM/aarch64: uses "Processor", "CPU implementer", "CPU part", etc.
        if let cpuinfo = try? String(contentsOfFile: "/proc/cpuinfo", encoding: .utf8) {
            let lines = cpuinfo.components(separatedBy: "\n")
            
            // Try multiple fields for CPU model (architecture-dependent)
            for line in lines {
                // x86_64: "model name"
                if line.hasPrefix("model name") {
                    let parts = line.components(separatedBy: ":")
                    if parts.count > 1 {
                        cpuModel = parts[1].trimmingCharacters(in: .whitespaces)
                        break
                    }
                }
                // ARM/aarch64: "Processor" (some systems)
                else if line.hasPrefix("Processor") && cpuModel == nil {
                    let parts = line.components(separatedBy: ":")
                    if parts.count > 1 {
                        cpuModel = parts[1].trimmingCharacters(in: .whitespaces)
                        // Don't break, continue to check for "model name" which is more specific
                    }
                }
            }
            
            // For ARM/aarch64, try to construct model from CPU implementer and part
            if cpuModel == nil {
                var implementer: String? = nil
                var part: String? = nil
                for line in lines {
                    if line.hasPrefix("CPU implementer") {
                        let parts = line.components(separatedBy: ":")
                        if parts.count > 1 {
                            implementer = parts[1].trimmingCharacters(in: .whitespaces)
                        }
                    } else if line.hasPrefix("CPU part") {
                        let parts = line.components(separatedBy: ":")
                        if parts.count > 1 {
                            part = parts[1].trimmingCharacters(in: .whitespaces)
                        }
                    }
                }
                if let impl = implementer, let p = part {
                    cpuModel = "ARM (implementer: \(impl), part: \(p))"
                }
            }
            
            // Count processor entries (works for all architectures)
            // Most Linux systems use "processor" prefix for each CPU core
            let processorCount = lines.filter { $0.hasPrefix("processor") }.count
            if processorCount > 0 {
                cpuCores = processorCount
            }
            // Note: If processorCount is 0, we leave cpuCores as nil
            // Some systems may not expose this information in /proc/cpuinfo
        }
        #endif
        
        // Swift Version
        // Note: This project requires Swift 6.0+ (see Package.swift: swift-tools-version: 6.0)
        // Use compile-time version detection for more granular version numbers
        var swiftVersion: String? = nil
        #if swift(>=6.3)
        swiftVersion = "6.3"
        #elseif swift(>=6.2)
        swiftVersion = "6.2"
        #elseif swift(>=6.1)
        swiftVersion = "6.1"
        #elseif swift(>=6.0)
        swiftVersion = "6.0"
        #else
        // Fallback for older Swift versions (should not occur in this project)
        swiftVersion = "unknown"
        #endif
        
        return HardwareInfo(
            cpuArchitecture: cpuArch,
            osName: osName,
            osVersion: osVersion,
            cpuModel: cpuModel,
            cpuCores: cpuCores,
            swiftVersion: swiftVersion
        )
    }
    
    #if os(macOS)
    /// Get sysctl string value (macOS only).
    private static func getSysctlString(_ name: String) -> String? {
        var size: size_t = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return nil }
        
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        
        // Remove null terminator and convert CChar (Int8) to UInt8 for UTF-8 decoding
        let trimmedBuffer = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: trimmedBuffer, as: UTF8.self)
    }
    
    /// Get sysctl integer value (macOS only).
    private static func getSysctlInt(_ name: String) -> Int? {
        var value: Int = 0
        var size = MemoryLayout<Int>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
    #endif
}

#if os(macOS)
import Darwin
#endif
