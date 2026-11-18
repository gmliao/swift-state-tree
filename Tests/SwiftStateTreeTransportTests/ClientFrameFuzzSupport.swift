// Tests/SwiftStateTreeTransportTests/ClientFrameFuzzSupport.swift
//
// The harness for the client-frame decoder fuzz tests (#528): a seeded generator, the corpus,
// the mutators and the runner. Each target gets inputs made from `(seed, target, iteration)`,
// so a run replays exactly from its seed. The oracle is "decode or throw": any thrown error
// passes, and a trap ends the test process, which fails the run.
//
// Budget: `SST_FUZZ_ITERATIONS` per target (default `ClientFrameFuzzConfig.defaultIterations`).
// Seed: `SST_FUZZ_SEED`, a decimal or `0x` number, or `random` (picked). Each target prints
// the seed before its first input, so a trap or a hang still leaves it in the output.
// `SST_FUZZ_LAST_INPUT=<path>` writes each target's input to `<path>.<target>` before decoding
// it, so after a trap that file holds the crasher: one file per target.
// When replaying, run the one target with `--filter`. A file write per input makes a run
// I/O-bound, so set it when replaying a seed that trapped, not for a long run. The seed and the
// target name are enough to replay a trap.

import Foundation
import Testing

// MARK: - Generator and configuration

/// SplitMix64, so a failure reproduces from its seed.
struct FuzzGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A generator for one target: the seed mixed with the target's name (FNV-1a).
    static func forTarget(_ target: String, seed: UInt64) -> FuzzGenerator {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in target.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return FuzzGenerator(state: seed ^ hash)
    }
}

enum ClientFrameFuzzEnvKeys {
    static let iterations = "SST_FUZZ_ITERATIONS"
    static let seed = "SST_FUZZ_SEED"
    static let lastInput = "SST_FUZZ_LAST_INPUT"
}

enum ClientFrameFuzzConfig {
    /// Iterations per target in a plain `swift test`.
    static let defaultIterations = 2_000
    static let defaultSeed: UInt64 = 0x0528

    static let iterations: Int = {
        guard let text = ProcessInfo.processInfo.environment[ClientFrameFuzzEnvKeys.iterations],
              let value = Int(text), value > 0 else { return defaultIterations }
        return value
    }()

    static let seed: UInt64 = {
        guard let text = ProcessInfo.processInfo.environment[ClientFrameFuzzEnvKeys.seed] else { return defaultSeed }
        if text == "random" { return UInt64.random(in: .min ... .max) }
        if text.hasPrefix("0x"), let value = UInt64(text.dropFirst(2), radix: 16) { return value }
        return UInt64(text) ?? defaultSeed
    }()

    /// The seed as `SST_FUZZ_SEED` takes it, for the lines each target prints.
    static var seedText: String { "0x" + String(seed, radix: 16) }

    static let lastInputPath: String? = ProcessInfo.processInfo.environment[ClientFrameFuzzEnvKeys.lastInput]
}

// MARK: - Corpus

enum FrameEncoding: String, CaseIterable, Sendable {
    case json
    case opcodeJsonArray
    case messagepack
}

struct CorpusFrame: Sendable {
    let name: String
    /// `join`, `action`, `clientEvent` or `syncAck`.
    let kind: String
    let encoding: FrameEncoding
    let bytes: [UInt8]
}

/// Frames a client sends: recorded from the TS SDK's encoders (`client-frames.json`, kept in
/// step by `sdk/ts/src/core/client-frames-fixture.test.ts`), and the action frames recorded
/// from the server's encoders (`payload-frames.json`), whose payloads are positional arrays.
/// That fixture's client-event frames aren't used: they carry the event type as a number,
/// which a client never sends and the server's inbound decoders refuse.
enum ClientFrameCorpus {
    static let fixturesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    /// The T5 seeds (`T5Seeds`) carry a valid value of each fixture payload type.
    static let frames: [CorpusFrame] = sdkFrames() + serverEncodedFrames() + T5Seeds.frames

    static func frames(_ encoding: FrameEncoding) -> [CorpusFrame] {
        frames.filter { $0.encoding == encoding }
    }

    private struct SDKFixture: Decodable {
        struct Frame: Decodable {
            let name: String
            let kind: String
            let encoding: String
            let base64: String
        }
        let frames: [Frame]
    }

    private static func sdkFrames() -> [CorpusFrame] {
        let url = fixturesDirectory.appendingPathComponent("ClientFrames/client-frames.json")
        guard let data = try? Data(contentsOf: url),
              let fixture = try? JSONDecoder().decode(SDKFixture.self, from: data) else {
            Issue.record("can't read \(url.path)")
            return []
        }
        return fixture.frames.compactMap { frame in
            guard let encoding = FrameEncoding(rawValue: frame.encoding),
                  let bytes = Data(base64Encoded: frame.base64) else {
                Issue.record("bad frame \(frame.name) in client-frames.json")
                return nil
            }
            return CorpusFrame(name: "sdk/\(frame.name)", kind: frame.kind, encoding: encoding, bytes: Array(bytes))
        }
    }

    private struct PayloadFixture: Decodable {
        struct Case: Decodable {
            let name: String
            let kind: String
            let jsonObject: String
            let opcodeJSON: String
            let opcodeJSONPlain: String
            let messagePack: String
            let messagePackPlain: String
        }
        let cases: [Case]
    }

    private static func serverEncodedFrames() -> [CorpusFrame] {
        let url = fixturesDirectory.appendingPathComponent("PayloadFrames/payload-frames.json")
        guard let data = try? Data(contentsOf: url),
              let fixture = try? JSONDecoder().decode(PayloadFixture.self, from: data) else {
            Issue.record("can't read \(url.path)")
            return []
        }
        var frames: [CorpusFrame] = []
        for entry in fixture.cases where entry.kind == "action" {
            let name = "server/\(entry.name)"
            frames.append(CorpusFrame(name: name, kind: entry.kind, encoding: .json, bytes: Array(entry.jsonObject.utf8)))
            frames.append(CorpusFrame(name: name, kind: entry.kind, encoding: .opcodeJsonArray, bytes: Array(entry.opcodeJSON.utf8)))
            frames.append(CorpusFrame(name: "\(name)-plain", kind: entry.kind, encoding: .opcodeJsonArray, bytes: Array(entry.opcodeJSONPlain.utf8)))
            for (suffix, base64) in [("", entry.messagePack), ("-plain", entry.messagePackPlain)] {
                if let bytes = Data(base64Encoded: base64) {
                    frames.append(CorpusFrame(name: name + suffix, kind: entry.kind, encoding: .messagepack, bytes: Array(bytes)))
                }
            }
        }
        return frames
    }
}

// MARK: - Mutators

enum FrameMutator {
    /// Byte values at type, sign and length boundaries.
    static let boundaryBytes: [UInt8] = [0x00, 0x01, 0x7F, 0x80, 0xFF, 0xFE, 0xC0, 0xC1]
    /// MessagePack headers that take a length or count, and fixed-width numbers.
    static let messagePackMarkers: [UInt8] = [
        0xC4, 0xC5, 0xC6,  // bin 8/16/32
        0xC7, 0xC8, 0xC9,  // ext 8/16/32
        0xCA, 0xCB,  // float 32/64
        0xCC, 0xCD, 0xCE, 0xCF,  // uint 8..64
        0xD0, 0xD1, 0xD2, 0xD3,  // int 8..64
        0xD4, 0xD5, 0xD6, 0xD7, 0xD8,  // fixext
        0xD9, 0xDA, 0xDB,  // str 8/16/32
        0xDC, 0xDD,  // array 16/32
        0xDE, 0xDF,  // map 16/32
        0x90, 0x9F, 0x80, 0x8F, 0xA0, 0xBF, 0xC0, 0xC2, 0xC3,
    ]
    /// JSON tokens a mutation can put in place of a value.
    static let jsonTokens: [String] = [
        "0", "-0", "-1", "1e309", "-1e309", "1e-400", "1.5", "9223372036854775807",
        "9223372036854775808", "-9223372036854775809", "18446744073709551616",
        "123456789012345678901234567890", "\"\\ud800\"", "\"\\udc00\\ud800\"", "\"\\u0000\"",
        "\"\"", "null", "true", "false", "[]", "{}", "[[[[[[[[]]]]]]]]", "{\"\":{\"\":{}}}",
        "\"\u{1F3AE}\"", "NaN", "Infinity", "\"\\", "[", "{", "]", "}", ",", ":",
    ]

    /// Applies one to four mutations to `bytes`; `other` is a second corpus entry for splicing.
    static func mutate(_ bytes: [UInt8], other: [UInt8], generator: inout FuzzGenerator) -> [UInt8] {
        var data = bytes
        let rounds = Int.random(in: 1...4, using: &generator)
        for _ in 0..<rounds {
            data = mutateOnce(data, other: other, generator: &generator)
        }
        return data
    }

    private static func mutateOnce(_ input: [UInt8], other: [UInt8], generator: inout FuzzGenerator) -> [UInt8] {
        var data = input
        func index(_ count: Int) -> Int { count == 0 ? 0 : Int.random(in: 0..<count, using: &generator) }
        switch Int.random(in: 0..<15, using: &generator) {
        case 13, 14:  // JSON element: the text between two adjacent separators becomes a token
            let separators = data.indices.filter { [0x2C, 0x3A, 0x5B, 0x5D, 0x7B, 0x7D].contains(data[$0]) }
            guard separators.count >= 2 else { break }
            let first = Int.random(in: 0..<(separators.count - 1), using: &generator)
            let range = (separators[first] + 1)..<separators[first + 1]
            data.replaceSubrange(range, with: Array(jsonTokens.randomElement(using: &generator)!.utf8))
        case 0 where !data.isEmpty:  // bit flip
            let i = index(data.count)
            data[i] ^= UInt8(1) << UInt8.random(in: 0..<8, using: &generator)
        case 1 where !data.isEmpty:  // boundary byte
            data[index(data.count)] = boundaryBytes.randomElement(using: &generator)!
        case 2 where !data.isEmpty:  // MessagePack marker
            data[index(data.count)] = messagePackMarkers.randomElement(using: &generator)!
        case 3 where !data.isEmpty:  // a length or count header followed by its maximum
            let i = index(data.count)
            let marker = [UInt8(0xDB), 0xDD, 0xDF, 0xC6, 0xC9].randomElement(using: &generator)!
            data.replaceSubrange(i..<min(data.count, i + 5), with: [marker, 0xFF, 0xFF, 0xFF, 0xFF])
        case 4 where !data.isEmpty:  // truncate
            data.removeSubrange(index(data.count)...)
        case 5:  // insert random bytes
            let insert = (0..<Int.random(in: 1...8, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) }
            data.insert(contentsOf: insert, at: index(data.count + 1))
        case 6 where !data.isEmpty:  // delete a range
            let start = index(data.count)
            data.removeSubrange(start..<min(data.count, start + Int.random(in: 1...16, using: &generator)))
        case 7 where !data.isEmpty:  // duplicate a range in place
            let start = index(data.count)
            let range = start..<min(data.count, start + Int.random(in: 1...32, using: &generator))
            data.insert(contentsOf: data[range], at: range.upperBound)
        case 8 where !other.isEmpty:  // splice: our head, the other entry's tail
            let cut = index(data.count + 1)
            data = Array(data[..<cut]) + Array(other[index(other.count)...])
        case 9:  // JSON token in place of a token-sized range
            let token = Array(jsonTokens.randomElement(using: &generator)!.utf8)
            let start = index(data.count + 1)
            let end = min(data.count, start + Int.random(in: 0...12, using: &generator))
            data.replaceSubrange(start..<end, with: token)
        case 10:  // wrap a range in nesting
            let depth = Int.random(in: 1...40, using: &generator)
            let start = index(data.count + 1)
            let end = min(data.count, start + Int.random(in: 0...24, using: &generator))
            let (open, close): (UInt8, UInt8) = Bool.random(using: &generator) ? (0x5B, 0x5D) : (0x91, 0x00)
            if open == 0x91 {
                // MessagePack: fixarray(1) headers before the range.
                data.insert(contentsOf: [UInt8](repeating: open, count: depth), at: start)
            } else {
                data.insert(contentsOf: [UInt8](repeating: close, count: depth), at: end)
                data.insert(contentsOf: [UInt8](repeating: open, count: depth), at: start)
            }
        case 11 where !data.isEmpty:  // duplicate a key-sized range: repeats a key or an element
            let start = index(data.count)
            let range = start..<min(data.count, start + Int.random(in: 2...12, using: &generator))
            data.insert(contentsOf: data[range], at: start)
        default:  // random bytes
            data = (0..<Int.random(in: 0...64, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) }
        }
        return data
    }
}

// MARK: - Runner

struct FuzzOutcome: CustomStringConvertible {
    var decoded = 0
    var threw = 0

    var description: String { "decoded=\(decoded) threw=\(threw)" }
}

/// `SST_FUZZ_LAST_INPUT`: writes each input of one target to `<path>.<target>` before it is
/// decoded. nil when the switch is off. A failed write is recorded once as an issue, and
/// recording stops.
struct FuzzInputRecorder {
    let url: URL
    let target: String
    private var failed = false

    init?(target: String) {
        guard let path = ClientFrameFuzzConfig.lastInputPath else { return nil }
        self.target = target
        url = URL(fileURLWithPath: "\(path).\(target)")
    }

    mutating func record(_ input: Data) {
        guard !failed else { return }
        do {
            try Data("\(target)\n\(input.base64EncodedString())\n".utf8).write(to: url, options: .atomic)
        } catch {
            failed = true
            Issue.record("can't write \(url.path): \(error)")
        }
    }
}

enum ClientFrameFuzzer {
    /// Inputs between yields. Each decode is synchronous CPU work; without a yield the targets
    /// hold the cooperative pool's threads for seconds and starve other suites' tasks, so a
    /// wall-clock deadline elsewhere expires before its test runs. The suites are also
    /// `.serialized`, so they use one pool thread at a time.
    static let inputsPerYield = 32

    /// Runs `decode` on each seed, then on `iterations` inputs mutated from `seeds`: decode or throw. Returns how
    /// many inputs decoded and how many threw; a trap ends the process.
    @discardableResult
    static func run(
        target: String,
        seeds: [[UInt8]],
        iterations: Int = ClientFrameFuzzConfig.iterations,
        seed: UInt64 = ClientFrameFuzzConfig.seed,
        decode: (Data) throws -> Void
    ) async -> FuzzOutcome {
        await run(target: target, seeds: seeds, iterations: iterations, seed: seed) { data, _ in try decode(data) }
    }

    /// `run(target:seeds:iterations:seed:decode:)`, telling `decode` whether the input is a
    /// mutation (true) or a seed replayed unmutated (false), so a target can count them apart.
    @discardableResult
    static func run(
        target: String,
        seeds: [[UInt8]],
        iterations: Int = ClientFrameFuzzConfig.iterations,
        seed: UInt64 = ClientFrameFuzzConfig.seed,
        decode: (_ data: Data, _ mutated: Bool) throws -> Void
    ) async -> FuzzOutcome {
        precondition(!seeds.isEmpty, "\(target): no seeds")
        // Before the loop: with `SST_FUZZ_SEED=random`, a trap or a hang in this target ends the
        // process, and this line is what names the seed to replay.
        print("[client-frame-fuzz] \(target) seed=\(ClientFrameFuzzConfig.seedText) iterations=\(iterations) started")
        var generator = FuzzGenerator.forTarget(target, seed: seed)
        var outcome = FuzzOutcome()
        var recorder = FuzzInputRecorder(target: target)
        // Each seed once unmutated, then the mutations: every decoder a seed reaches runs on a
        // valid input at least once, so each target's "decoded" count can't be zero by chance.
        for index in 0..<(seeds.count + iterations) {
            if index % inputsPerYield == 0 { await Task.yield() }
            let input: Data
            if index < seeds.count {
                input = Data(seeds[index])
            } else {
                let base = seeds.randomElement(using: &generator)!
                let other = seeds.randomElement(using: &generator)!
                input = Data(FrameMutator.mutate(base, other: other, generator: &generator))
            }
            recorder?.record(input)
            do {
                try decode(input, index >= seeds.count)
                outcome.decoded += 1
            } catch {
                outcome.threw += 1
            }
        }
        print("[client-frame-fuzz] \(target) \(outcome)")
        return outcome
    }
}
