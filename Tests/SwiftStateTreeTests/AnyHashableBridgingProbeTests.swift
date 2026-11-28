// Tests/SwiftStateTreeTests/AnyHashableBridgingProbeTests.swift
//
// PROBE for #927, not a test to merge. Where does Darwin trap ("Duplicate keys of type
// 'AnyHashable' were found in a Dictionary") on an NSDictionary that holds two spellings of one
// key (NFC and NFD)? In the caller's `AnyHashable(ns)`, or in the `as? [String: Any]` cast that
// `AnyCodable.encode(to:)` runs? Each case is an exit test, so a trap ends a child process. The
// child writes a marker to standard error (unbuffered, so it precedes a trap's message) after each
// step, and the parent prints what the child wrote and how it exited, prefixed "PROBE927". Enabled only on Darwin and only in CI (`CI` is set on
// GitHub runners): a trap must not run on a developer's Mac.

import Foundation
import Testing
@testable import SwiftStateTree

#if canImport(Darwin)
private let probeEnabled = ProcessInfo.processInfo.environment["CI"] != nil
#else
private let probeEnabled = false
#endif

/// An NSMutableDictionary with "e" + U+0301 and U+00E9 as two entries (Darwin compares NSString
/// keys literally).
/// A marker line on standard error, which isn't buffered.
private func mark(_ text: String) {
    FileHandle.standardError.write(Data("MARK \(text)\n".utf8))
}

private func twoSpellings() -> NSMutableDictionary {
    let dictionary = NSMutableDictionary()
    dictionary["e\u{301}"] = 1
    dictionary["\u{E9}"] = 2
    mark("built ns count=\(dictionary.count)")
    return dictionary
}

private func report(_ name: String, _ result: ExitTest.Result?) {
    guard let result else {
        print("PROBE927 \(name): no result (the exit condition didn't match)")
        return
    }
    let out = String(decoding: result.standardOutputContent, as: UTF8.self)
    let err = String(decoding: result.standardErrorContent, as: UTF8.self)
    print("PROBE927 \(name): exit=\(result.exitStatus)\n--- stdout\n\(out)--- stderr\n\(err)--- end \(name)")
}

@Suite("PROBE #927: where the AnyHashable bridging trap is", .enabled(if: probeEnabled))
struct AnyHashableBridgingProbeTests {
    @Test("A: AnyHashable(ns) alone")
    func anyHashableConstruction() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent, \.standardErrorContent]) {
            let ns = twoSpellings()
            let hashable = AnyHashable(ns)
            mark("built AnyHashable base=\(type(of: hashable.base))")
        }
        report("A", result)
    }

    @Test("B: the cast AnyCodable runs, on the NSDictionary itself (no AnyHashable)")
    func castOnNSDictionary() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent, \.standardErrorContent]) {
            let ns = twoSpellings()
            let boxed: Any = ns
            mark("boxed")
            let cast = boxed as? [String: Any]
            mark("cast count=\(cast.map { String($0.count) } ?? "nil")")
        }
        report("B", result)
    }

    @Test("C: AnyHashable(ns), boxed in Any, then the cast (Review's split)")
    func castOnAnyHashable() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent, \.standardErrorContent]) {
            let ns = twoSpellings()
            let hashable = AnyHashable(ns)
            mark("built")
            let boxed: Any = hashable
            mark("boxed")
            _ = boxed as? [String: Any]
            mark("cast")
        }
        report("C", result)
    }

    @Test("D: ns as? [AnyHashable: Any] in the caller")
    func conditionalBridgeToAnyHashableKeys() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent, \.standardErrorContent]) {
            let ns = twoSpellings()
            let bridged = ns as? [AnyHashable: Any]
            mark("bridged count=\(bridged.map { String($0.count) } ?? "nil")")
        }
        report("D", result)
    }

    @Test("E: AnyCodable(ns) through JSONEncoder and the canonical encoder")
    func anyCodableEncodes() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent, \.standardErrorContent]) {
            let ns = twoSpellings()
            let json = try? JSONEncoder().encode(AnyCodable(ns))
            mark("json=\(json.map { String(decoding: $0, as: UTF8.self) } ?? "error")")
            do {
                _ = try CanonicalMessagePack.encode(AnyCodable(ns))
                mark("canonical=encoded")
            } catch {
                mark("canonical=\(error)")
            }
        }
        report("E", result)
    }
}
