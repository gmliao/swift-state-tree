// P-909-1 (#909 plan): a new requirement with a default, added to a protocol whose conformer
// already has a same-signature method. Called through the existential, which one runs? And,
// rev 2 (Review's should 1): a conformer with only the older two-argument ordered close keeps
// its ordering through the new call when the close is `.normal`.
// Run: swiftc -swift-version 6 -o p909 main.swift && ./p909
public struct Close: Sendable, Equatable {
    public let code: UInt16
    public static let normal = Close(code: 1000)
}

public protocol Port: Sendable {
    func closeAtOnce(_ id: String, with close: Close, generation: UInt64?) async
    func closeAfterQueued(_ id: String, generation: UInt64?) async
    // New in #909: the ordered close with a code.
    func closeAfterQueued(_ id: String, generation: UInt64?, with close: Close) async
}

extension Port {
    public func closeAtOnce(_ id: String, with close: Close, generation: UInt64?) async { print("default at once: \(close.code)") }
    public func closeAfterQueued(_ id: String, generation: UInt64?) async { await closeAtOnce(id, with: .normal, generation: generation) }
    // `.normal` keeps the older ordered close; another code closes at once with it, as the
    // supersede's detached close does today.
    public func closeAfterQueued(_ id: String, generation: UInt64?, with close: Close) async {
        if close == .normal {
            await closeAfterQueued(id, generation: generation)
        } else {
            await closeAtOnce(id, with: close, generation: generation)
        }
    }
}

/// WebSocketTransport after #909: both ordered closes.
public actor Concrete: Port {
    public init() {}
    public func closeAfterQueued(_ id: String, generation: UInt64?) async { print("concrete ordered 2-arg") }
    public func closeAfterQueued(_ id: String, generation: UInt64?, with close: Close) async {
        print("concrete ordered with: \(close.code)")
    }
}

/// A transport written before #909: only the two-argument ordered close.
public actor OlderOrdered: Port {
    public init() {}
    public func closeAfterQueued(_ id: String, generation: UInt64?) async { print("older ordered 2-arg") }
}

/// A transport with no ordered close at all.
public actor Plain: Port { public init() {} }

let ports: [(String, any Port)] = [("concrete", Concrete()), ("older", OlderOrdered()), ("plain", Plain())]
for (name, port) in ports {
    print("-- \(name)")
    await port.closeAfterQueued("a", generation: 1, with: .normal)
    await port.closeAfterQueued("a", generation: 1, with: Close(code: 4017))
}
