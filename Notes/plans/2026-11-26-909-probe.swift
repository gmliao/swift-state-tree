// P-909-1 (#909 plan): a new requirement with a default, added to a protocol whose conformer
// already has a same-signature method. Called through the existential, which one runs?
// Run: swiftc -swift-version 6 -o p909 main.swift && ./p909
public struct Close: Sendable { public let code: UInt16 }

public protocol Port: Sendable {
    func closeAfterQueued(_ id: String, generation: UInt64?) async
    // New in #909: the ordered close with a code.
    func closeAfterQueued(_ id: String, generation: UInt64?, with close: Close) async
}

extension Port {
    public func closeAfterQueued(_ id: String, generation: UInt64?) async { print("default 2-arg") }
    // Default for transports without an ordered close: closes at once, with the code.
    public func closeAfterQueued(_ id: String, generation: UInt64?, with close: Close) async {
        print("default with: \(close.code)")
    }
}

public actor Concrete: Port {
    public init() {}
    public func closeAfterQueued(_ id: String, generation: UInt64?) async { print("concrete 2-arg") }
    // Today this is `package` in WebSocketTransport; as the witness it must be public.
    public func closeAfterQueued(_ id: String, generation: UInt64?, with close: Close) async {
        print("concrete with: \(close.code)")
    }
}

public actor Plain: Port { public init() {} }

let ports: [any Port] = [Concrete(), Plain()]
for port in ports {
    await port.closeAfterQueued("a", generation: 1, with: Close(code: 4017))
}
let concrete = Concrete()
await concrete.closeAfterQueued("a", generation: 1, with: Close(code: 4017))
