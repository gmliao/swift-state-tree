import SwiftStateTree

private let _testLoggerOverrides: Void = {
    LoggerDefaults.setOverrides(logLevel: .error, useColors: false)
    return ()
}()
