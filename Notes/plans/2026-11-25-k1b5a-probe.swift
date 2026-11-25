// K1b-5a rev 3 probe: withModel's return value vs its defer, the submitting variant,
// and the sentinel's failure applied inside the body vs in the defer.
// Build: swiftc -swift-version 6 -parse-as-library 2026-11-25-k1b5a-probe.swift -o probe && ./probe

import Foundation

/// Appended from the actor and from the recorder Tasks, so it takes a lock.
final class Trace: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    var lines: [String] { lock.withLock { _lines } }
    func add(_ s: String) { lock.withLock { _lines.append(s) } }
}

struct Model { var count = 0; var failure: String? = nil }

enum Effect { case submit(String) }

struct Outputs { var effects: [Effect] = [] }

struct Side {
    let trace: Trace
    var mailbox: String? = nil
    /// Applies the staged effects in call order; returns the last submission's handle.
    @discardableResult
    mutating func flush(_ out: inout Outputs) -> Task<Void, Never>? {
        var last: Task<Void, Never>?
        for e in out.effects {
            switch e {
            case .submit(let name):
                trace.add("submit \(name)")
                let t = trace
                last = Task { t.add("recorded \(name)") }
            }
        }
        out.effects.removeAll()
        return last
    }
}

enum SyncResult: Equatable { case committed, landFailed }

actor Keeper {
    var model = Model()
    var side: Side
    var bodyDepth = 0
    var violations = 0
    let trace: Trace
    init(trace: Trace) { self.trace = trace; self.side = Side(trace: trace) }

    // ---- MF2: rev 2's shape. The result is fixed before the defer flushes.
    func withModel<R>(_ step: (inout Model, inout Side, inout Outputs) -> R) -> R {
        var out = Outputs()
        defer {
            let h = side.flush(&out)
            trace.add("defer flushed, handle \(h == nil ? "nil" : "made") after the result was fixed")
        }
        bodyDepth += 1
        defer { bodyDepth -= 1 }
        let r = step(&model, &side, &out)
        trace.add("result fixed")
        return r
    }

    // ---- MF2: the submitting variant. Inner scope lowers the depth; explicit flush returns
    // the handle; a consuming defer covers the throw path.
    func withModelSubmitting<R>(_ step: (inout Model, inout Side, inout Outputs) throws -> R) rethrows -> (R, Task<Void, Never>?) {
        var out = Outputs()
        var flushed = false
        defer { if !flushed { side.flush(&out); trace.add("throw path flushed") } }
        let r: R
        do {
            bodyDepth += 1
            defer { bodyDepth -= 1 }
            r = try step(&model, &side, &out)
        }
        trace.add("depth \(bodyDepth) before the flush")
        let handle = side.flush(&out)
        flushed = true
        return (r, handle)
    }

    func submitTurnRecord() async {
        let (_, handle) = withModelSubmitting { m, side, out in
            m.count += 1
            out.effects.append(.submit("ordinary draft"))
        }
        trace.add(".turnRecord hold (handle \(handle == nil ? "nil" : "made"))")
        await handle?.value
        trace.add("awaited that exact task; resume consumed waiters")
    }

    func rev2Shape() {
        _ = withModel { m, _, out in out.effects.append(.submit("draft")); return 1 }
    }

    func throwing() {
        struct E: Error {}
        do {
            _ = try withModelSubmitting { m, side, out -> Int in
                out.effects.append(.submit("staged before throw"))
                throw E()
            }
        } catch { trace.add("caught; depth \(bodyDepth)") }
    }

    // ---- MF1: a port call that re-enters and trips the sentinel.
    nonisolated func portCall(_ keeper: Keeper) {
        keeper.assumeIsolated { k in
            if k.bodyDepth > 0 {
                k.violations += 1
                k.side.mailbox = "keeperReentry"   // side field, not the model (probe only)
                k.trace.add("sentinel: mailbox posted, gate closed")
            }
        }
    }

    /// The sync-only body. `checkAfterPort` is rev 3's fix.
    func syncOnlyTurn(checkAfterPort: Bool) -> SyncResult {
        let before = violations
        var out = Outputs()
        var result: SyncResult
        bodyDepth += 1
        do {
            defer { bodyDepth -= 1 }
            let mark = model.count
            portCall(self)
            if checkAfterPort, let f = side.mailbox {
                model.failure = f
                model.count += 1; out.effects.append(.submit("terminal entry \(f)"))
                model.count += 1; out.effects.append(.submit("endTurn"))
                result = .landFailed
            } else {
                model.count += 1; out.effects.append(.submit("sync-stream draft"))
                if model.count != mark { model.count += 1; out.effects.append(.submit("endTurn")) }
                result = .committed
            }
        }
        side.flush(&out)
        if violations != before, model.failure == nil, let f = side.mailbox {
            model.failure = f
            var late = Outputs(); late.effects.append(.submit("terminal entry \(f) (late)"))
            side.flush(&late)
        }
        trace.add("returned \(result)")
        return result
    }
}

@main struct Probe {
    static func main() async {
        func run(_ title: String, _ body: (Keeper, Trace) async -> Void) async {
            print("-> \(title)"); let t = Trace(); let k = Keeper(trace: t)
            await body(k, t)
            for _ in 0..<1000 { await Task.yield() }
            print("== \(title)"); t.lines.forEach { print("  \($0)") }
        }
        await run("MF2 rev 2: return value vs defer") { k, _ in
            await k.rev2Shape()
        }
        await run("MF2 rev 3: withModelSubmitting + .turnRecord") { k, _ in await k.submitTurnRecord() }
        await run("MF2 rev 3: throw path") { k, _ in await k.throwing() }
        await run("MF1 rev 2: failure applied in the defer") { k, _ in _ = await k.syncOnlyTurn(checkAfterPort: false) }
        await run("MF1 rev 3: failure applied after the port call") { k, _ in _ = await k.syncOnlyTurn(checkAfterPort: true) }
    }
}
