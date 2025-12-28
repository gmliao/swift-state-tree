import Foundation
import Logging

/// Colored logger with scope support (similar to NestJS)
///
/// This module provides:
/// - Colored log output based on log level (INFO=green, ERROR=red, etc.)
/// - Scope/context support (e.g., `[TransportAdapter]`, `[WebSocketTransport]`)
/// - Structured metadata support
///
/// Example usage:
/// ```swift
/// let logger = createColoredLogger(
///     loggerIdentifier: "com.swiftstatetree.transport",
///     scope: "TransportAdapter"
/// )
/// logger.info("Client connected", metadata: ["sessionID": "123"])
/// ```
///
/// Output format (similar to NestJS):
/// ```
/// 2025-12-05 15:44:43.639 INFO   [TransportAdapter] Client connected sessionID=123
/// ```

/// ANSI color codes for terminal output
public enum ANSIColor: String {
    case black = "\u{001B}[0;30m"
    case red = "\u{001B}[0;31m"
    case green = "\u{001B}[0;32m"
    case yellow = "\u{001B}[0;33m"
    case blue = "\u{001B}[0;34m"
    case magenta = "\u{001B}[0;35m"
    case cyan = "\u{001B}[0;36m"
    case white = "\u{001B}[0;37m"
    case reset = "\u{001B}[0m"
    case bold = "\u{001B}[1m"
    
    /// Color for log levels (similar to NestJS)
    static func forLevel(_ level: Logger.Level) -> ANSIColor {
        switch level {
        case .trace: return .gray
        case .debug: return .cyan
        case .info: return .green
        case .notice: return .blue
        case .warning: return .yellow
        case .error: return .red
        case .critical: return .red
        }
    }
    
    /// Gray color (not in standard ANSI, using bright black)
    static var gray: ANSIColor {
        .black
    }
}

/// A colored log handler that supports scope/context (similar to NestJS)
public struct ColoredLogHandler: LogHandler {
    private let loggerIdentifier: String
    private var _metadata: Logger.Metadata = [:]
    private var _logLevel: Logger.Level
    private let useColors: Bool
    private let dateFormatter: DateFormatter
    
    public init(
        loggerIdentifier: String,
        logLevel: Logger.Level = .info,
        useColors: Bool = true
    ) {
        self.loggerIdentifier = loggerIdentifier
        self._logLevel = logLevel
        self.useColors = useColors
        
        self.dateFormatter = DateFormatter()
        self.dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        self.dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        self.dateFormatter.timeZone = TimeZone.current
    }
    
    public func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        // Early return if log level is below threshold
        // This provides an additional safety check (Swift Logging framework also filters at call site)
        guard self.logLevel <= level else {
            return
        }
        
        let timestamp = dateFormatter.string(from: Date())
        let levelColor = useColors ? ANSIColor.forLevel(level) : nil
        let reset = useColors ? ANSIColor.reset.rawValue : ""
        
        // Format level string (similar to NestJS)
        let levelString = formatLevel(level, color: levelColor, reset: reset)
        
        // Format scope/context
        let scopeString = formatScope(metadata: metadata, reset: reset)
        
        // Format message
        let formattedMessage = formatMessage(
            message: message,
            metadata: metadata,
            reset: reset
        )
        
        // Build final log line (similar to NestJS format)
        let logLine = "\(timestamp) \(levelString)\(scopeString)\(formattedMessage)\(reset)\n"
        
        // Output to stderr for errors, stdout for others
        let output: FileHandle = (level >= .error) ? .standardError : .standardOutput
        if let data = logLine.data(using: .utf8) {
            output.write(data)
        }
    }
    
    private func formatLevel(_ level: Logger.Level, color: ANSIColor?, reset: String) -> String {
        let levelName = level.rawValue.uppercased().padding(toLength: 5, withPad: " ", startingAt: 0)
        let colorCode = color?.rawValue ?? ""
        return "\(colorCode)\(levelName)\(reset)"
    }
    
    private func formatScope(metadata: Logger.Metadata?, reset: String) -> String {
        // Extract scope from metadata
        if let scope = metadata?["scope"]?.description ?? self._metadata["scope"]?.description {
            let scopeColor = useColors ? ANSIColor.cyan.rawValue : ""
            return " \(scopeColor)[\(scope)]\(reset)"
        }
        return ""
    }
    
    private func formatMessage(
        message: Logger.Message,
        metadata: Logger.Metadata?,
        reset: String
    ) -> String {
        var result = " \(message.description)"
        
        // Add additional metadata (excluding scope which is already shown)
        let additionalMetadata = (metadata ?? [:]).merging(self._metadata) { _, new in new }
            .filter { $0.key != "scope" }
        
        if !additionalMetadata.isEmpty {
            let metadataString = additionalMetadata.map { "\($0.key)=\($0.value)" }
                .joined(separator: ", ")
            result += " \(useColors ? ANSIColor.gray.rawValue : "")\(metadataString)\(reset)"
        }
        
        return result
    }
    
    public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get {
            return _metadata[key]
        }
        set {
            _metadata[key] = newValue
        }
    }
    
    public var metadata: Logger.Metadata {
        get {
            return _metadata
        }
        set {
            _metadata = newValue
        }
    }
    
    public var logLevel: Logger.Level {
        get {
            return _logLevel
        }
        set {
            _logLevel = newValue
        }
    }
}

/// Extension to create logger with scope support
extension Logger {
    /// Create a logger with a specific scope/context
    public func withScope(_ scope: String) -> Logger {
        var logger = self
        logger[metadataKey: "scope"] = .string(scope)
        return logger
    }
    
    /// Create a new logger with scope
    public static func withScope(_ scope: String, loggerIdentifier: String? = nil) -> Logger {
        let identifier = loggerIdentifier ?? "com.swiftstatetree"
        var logger = Logger(label: identifier)
        logger[metadataKey: "scope"] = .string(scope)
        return logger
    }
    
    /// Safely generate a UTF-8 string preview from Data for logging
    /// Only computes the preview if the specified log level is enabled
    /// - Parameters:
    ///   - data: The data to convert to string
    ///   - level: The log level to check (default: .trace)
    ///   - maxLength: Maximum length of the preview (default: nil, no limit)
    /// - Returns: The string preview, or nil if the log level is not enabled
    public func safePreview(from data: Data, level: Logger.Level = .trace, maxLength: Int? = nil) -> String? {
        // Only compute preview if the specified log level is enabled
        guard self.logLevel <= level else {
            return nil
        }
        
        guard let preview = String(data: data, encoding: .utf8) else {
            return "<non-UTF8 payload>"
        }
        
        if let maxLength = maxLength, preview.count > maxLength {
            return String(preview.prefix(maxLength)) + "..."
        }
        
        return preview
    }
}

public enum LoggerDefaults {
    private static let lock = NSLock()
    private static nonisolated(unsafe) var _overrideLogLevel: Logger.Level?
    private static nonisolated(unsafe) var _overrideUseColors: Bool?
    private static let isRunningTests: Bool = {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        if environment["SWIFT_TESTING"] != nil {
            return true
        }
        if environment["SWIFT_TESTING_ENABLED"] != nil {
            return true
        }
        if environment["SWIFTPM_TEST"] != nil {
            return true
        }
        if Bundle.main.bundlePath.hasSuffix(".xctest") {
            return true
        }
        if NSClassFromString("XCTestCase") != nil {
            return true
        }
        return false
    }()

    public static func setOverrides(logLevel: Logger.Level?, useColors: Bool?) {
        lock.lock()
        _overrideLogLevel = logLevel
        _overrideUseColors = useColors
        lock.unlock()
    }

    static func currentOverrides() -> (Logger.Level?, Bool?) {
        lock.lock()
        let overrides = (_overrideLogLevel, _overrideUseColors)
        lock.unlock()
        if overrides.0 == nil, overrides.1 == nil, isRunningTests {
            return (.error, false)
        }
        return overrides
    }
}

/// Helper to create a colored logger with scope
public func createColoredLogger(
    loggerIdentifier: String,
    scope: String? = nil,
    logLevel: Logger.Level = .info,
    useColors: Bool = true
) -> Logger {
    let (overrideLogLevel, overrideUseColors) = LoggerDefaults.currentOverrides()
    let resolvedLogLevel = overrideLogLevel ?? logLevel
    let resolvedUseColors = overrideUseColors ?? useColors
    let handler = ColoredLogHandler(
        loggerIdentifier: loggerIdentifier,
        logLevel: resolvedLogLevel,
        useColors: resolvedUseColors
    )
    
    var logger = Logger(label: loggerIdentifier) { _ in handler }
    
    if let scope = scope {
        logger[metadataKey: "scope"] = .string(scope)
    }
    
    return logger
}
