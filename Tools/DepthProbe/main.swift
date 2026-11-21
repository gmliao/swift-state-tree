// Tools/DepthProbe/main.swift (scratch branch s0/716-depth-probe only; never merged).
//
// #716 S0: finds the depth at which each recursive stage overflows its thread's stack. One run
// converts, encodes or decodes one value of one depth in one context, then prints one JSON line
// and exits 0 (the stage returned) or 3 (the stage threw: a clean refusal). A stack overflow
// kills the process with a signal, which the caller records from the exit status.
//
// Usage: DepthProbe --stage <make|full|json|pack|unpack|pack-unbounded|unpack-unbounded|
//                           optional-any|optional-any-full|optional-array|
//                           optional-any-unbounded|optional-array-unbounded|optional-array-build|
//                           optional-array-root-refused|any-array-root-refused|release>
//                   --depth <n>
//                   --context <pool|thread> [--stack-kib <n>]

import Foundation
import SwiftStateTree
import SwiftStateTreeMessagePack

@StateNodeBuilder
struct ProbeNode: StateNodeProtocol {
    @Sync(.broadcast) var children: [String: ProbeNode] = [:]
    init() {}
}

/// A chain of `depth` nodes, each the only child of the one above: 2 containers per level.
func nodeChain(_ depth: Int) -> ProbeNode {
    var node = ProbeNode()
    for _ in 1..<max(depth, 1) {
        var parent = ProbeNode()
        parent.children = ["c": node]
        node = parent
    }
    return node
}

/// `depth` nested arrays, built iteratively.
func nestedSnapshot(_ depth: Int) -> SnapshotValue {
    var value = SnapshotValue.null
    for _ in 0..<depth { value = .array([value]) }
    return value
}

func nestedPack(_ depth: Int) -> MessagePackValue {
    var value = MessagePackValue.nil
    for _ in 0..<depth { value = .array([value]) }
    return value
}

/// A plain struct: no cast in `make` matches it, so it converts through `Mirror`.
struct ProbeLeaf {
    var hp = 1
}

/// `depth` nested `Optional<Any>` around a `ProbeLeaf`: every level is an unwrap through
/// `Mirror` (a hop, no container), the shape `make`'s hop path sees.
func optionalAnyChain(_ depth: Int) -> Any {
    var value: Any = ProbeLeaf()
    for _ in 0..<depth { value = Optional<Any>.some(value) as Any }
    return value
}

/// `depth` levels of a one-element `[Any]` holding an `Optional<Any>`: one container and one
/// hop per level.
func optionalArrayChain(_ depth: Int) -> Any {
    var value: Any = ProbeLeaf()
    for _ in 0..<depth { value = [Optional<Any>.some(value) as Any] as [Any] }
    return value
}

/// `depth` nested one-element `[Any]` around a `ProbeLeaf`.
func nestedAnyArray(_ depth: Int) -> Any {
    var value: Any = ProbeLeaf()
    for _ in 0..<depth { value = [value] as [Any] }
    return value
}

/// A budget no probed value spends: `NestingBudget(containers:hops:)` is `package`.
let unboundedBudget = NestingBudget(containers: Int.max, hops: Int.max)

/// `depth` one-element MessagePack arrays around a nil, as bytes.
func nestedBytes(_ depth: Int) -> Data {
    Data(repeating: 0x91, count: depth) + Data([0xc0])
}

/// Keeps a stage's input and output alive until the process exits, so their release (a
/// recursion of its own) isn't counted as the stage's: only the `release` stage measures it.
final class KeepAlive: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Any] = []
    func keep(_ items: Any...) { lock.withLock { self.items.append(contentsOf: items) } }
}

let keepAlive = KeepAlive()

struct Options {
    var stage = "make"
    var depth = 8
    var context = "pool"
    var stackKiB = 544
}

func parse() -> Options {
    var o = Options()
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let flag = args.next() {
        let value = args.next() ?? ""
        switch flag {
        case "--stage": o.stage = value
        case "--depth": o.depth = Int(value) ?? o.depth
        case "--context": o.context = value
        case "--stack-kib": o.stackKiB = Int(value) ?? o.stackKiB
        default:
            FileHandle.standardError.write(Data("unknown flag \(flag)\n".utf8))
            exit(2)
        }
    }
    return o
}

/// Runs the stage; returns nil when it returned, or the error's description when it threw.
/// The value is built before the timed part, so only the stage itself recurses.
func runStage(_ o: Options) -> String? {
    do {
        switch o.stage {
        case "make":
            let root = nodeChain(o.depth)
            keepAlive.keep(root)
            keepAlive.keep(try SnapshotValue.make(from: root))
        case "full":
            let root = nodeChain(o.depth)
            keepAlive.keep(root)
            keepAlive.keep(try SnapshotValue.makeFull(from: root))
        case "json":
            let value = nestedSnapshot(o.depth)
            keepAlive.keep(value)
            keepAlive.keep(try JSONEncoder().encode(value))
        case "pack":
            let value = nestedPack(o.depth)
            keepAlive.keep(value)
            keepAlive.keep(try pack(value))
        case "unpack":
            let bytes = nestedBytes(o.depth)
            keepAlive.keep(try unpack(bytes))
        case "pack-unbounded":
            // The package entry point without the public default's depth limit: where the
            // packer's own recursion overflows.
            let value = nestedPack(o.depth)
            keepAlive.keep(value)
            keepAlive.keep(try pack(value, maxDepth: Int.max))
        case "unpack-unbounded":
            let bytes = nestedBytes(o.depth)
            keepAlive.keep(try unpack(bytes, maxDepth: Int.max))
        case "optional-any":
            let value = optionalAnyChain(o.depth)
            keepAlive.keep(value)
            keepAlive.keep(try SnapshotValue.make(from: value))
        case "optional-any-full":
            let value = optionalAnyChain(o.depth)
            keepAlive.keep(value)
            keepAlive.keep(try SnapshotValue.makeFull(from: value))
        case "optional-array":
            let value = optionalArrayChain(o.depth)
            keepAlive.keep(value)
            keepAlive.keep(try SnapshotValue.make(from: value))
        case "optional-any-unbounded":
            // The limited entry point with a budget no chain reaches: where the unwrap path's
            // own recursion would overflow, for the hop limit's margin.
            let value = optionalAnyChain(o.depth)
            keepAlive.keep(value)
            keepAlive.keep(try SnapshotValue.make(from: value, budget: unboundedBudget))
        case "optional-array-unbounded":
            let value = optionalArrayChain(o.depth)
            keepAlive.keep(value)
            keepAlive.keep(try SnapshotValue.make(from: value, budget: unboundedBudget))
        case "optional-array-build":
            // Only builds the value: a crash here is the probe's input, not a conversion.
            keepAlive.keep(optionalArrayChain(o.depth))
        case "optional-array-root-refused":
            // Converts with no container left: every cast `make` runs before it recurses runs
            // on the outermost value, then the first container is refused. A crash here is a
            // cast that looks into the nested value.
            let value = optionalArrayChain(o.depth)
            keepAlive.keep(value)
            keepAlive.keep(try SnapshotValue.make(from: value, budget: NestingBudget(containers: 0, hops: 0)))
        case "any-array-root-refused":
            // The same with plain nested `[Any]`, no `Optional`: whether the `Optional` matters.
            let value = nestedAnyArray(o.depth)
            keepAlive.keep(value)
            keepAlive.keep(try SnapshotValue.make(from: value, budget: NestingBudget(containers: 0, hops: 0)))
        case "release":
            // The uniquely owned tree's deinit recurses once per level.
            var value: SnapshotValue? = nestedSnapshot(o.depth)
            value = nil
            _ = value
        default:
            FileHandle.standardError.write(Data("unknown stage \(o.stage)\n".utf8))
            exit(2)
        }
        return nil
    } catch {
        return String(describing: error)
    }
}

/// The stage's outcome, written once by the thread or task that ran it.
final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func set(_ newValue: String?) { lock.withLock { value = newValue } }
    func get() -> String? { lock.withLock { value } }
}

let options = parse()
let box = OutcomeBox()
let done = DispatchSemaphore(value: 0)
switch options.context {
case "thread":
    // A thread with the given stack, as the smallest stack a stage runs on (Darwin's
    // cooperative pool threads have 544 KiB).
    let thread = Thread {
        box.set(runStage(options))
        done.signal()
    }
    thread.stackSize = options.stackKiB * 1024
    thread.start()
case "pool":
    // A task on the cooperative pool, as the keeper's and the adapter's turns run.
    Task.detached {
        box.set(runStage(options))
        done.signal()
    }
default:
    FileHandle.standardError.write(Data("unknown context \(options.context)\n".utf8))
    exit(2)
}
done.wait()
let outcome = box.get()
let stack = options.context == "thread" ? "\(options.stackKiB)" : "null"
let error = outcome.map { "\"" + $0.replacingOccurrences(of: "\"", with: "'") + "\"" } ?? "null"
print("{\"stage\":\"\(options.stage)\",\"depth\":\(options.depth),\"context\":\"\(options.context)\",\"stackKiB\":\(stack),\"outcome\":\"\(outcome == nil ? "ok" : "refused")\",\"error\":\(error)}")
exit(outcome == nil ? 0 : 3)
