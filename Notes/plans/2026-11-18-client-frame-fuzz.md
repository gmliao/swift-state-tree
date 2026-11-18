# Fuzz the decoders that read client frames (#528, #362)

Status: plan, rev 1. Branch `test/528-client-frame-fuzz` from main 382814a8.

## Goal

Every decoder that reads bytes a client sent either decodes or throws, for any input. A trap, a crash, a stack overflow (unbounded recursion) or a hang is a failure. The harness is a Swift Testing suite: seeded, mutation-based, deterministic, a small fixed budget in `swift test`, and a longer opt-in run through the environment. Linux on the pinned toolchain (6.2.4) is the gate.

Solutions consulted:
- `2026-11-09-wire-fed-integer-conversions-must-be-exact-and-throwing`: the class this guards (an `Int(x)` on a wire value traps).
- `2026-11-09-an-id-a-client-can-build-is-not-an-authorization`: join fields are client-built.
- `2026-11-10-skip-build-after-a-failed-build-runs-the-old-tests`: the harness is verified by mutants, so each mutant run rebuilds.

## Targets

What a client's bytes reach, and when:

| # | Entry point | Reachable | Encodings |
|---|---|---|---|
| T1 | `LandRouter` handshake decode: the opcode-array probe (`JSONSerialization`, then `OpcodeTransportMessageDecoder.decode`) or `JSONTransportCodec.decode(TransportMessage.self)` | **before join** (unauthenticated) | JSON object, opcode JSON array |
| T2 | `SyncAckFrame.parse` (`parseJSON`, `parseMessagePack`) | after join | JSON, MessagePack |
| T3 | `MessageDecodingPipeline.decode` (the adapter's path), with legacy join on and off, and the router's post-handshake branch (the same three calls) | after join | all three |
| T4 | MessagePack below T3: `unpack` (`MessagePackValue`), `MessagePackDirectDecoder.decodeTransportMessage`, `MessagePackValueDecoder` | after join | MessagePack |
| T5 | Payload decode after routing (detail below) | after join | the `AnyCodable` T3 produced, in each encoding |
| T6 | Join payload fields after decode: the identity fields and the `metadata: [String: AnyCodable]` walk, up to the join handler's own validation (no land is created) | before join | JSON object, opcode JSON array |
| T7 | Deep nesting (#362): the chain T1/T3 then T5, at depths up to each parser's limit, on a cooperative-pool task, in a debug build | both | all three |

T5 in detail:
- An action's `AnyCodable` is re-encoded and decoded as the action type (`LandKeeper`, `JSONEncoder` then `JSONDecoder`). A client event takes the same route, in `LandDefinition`'s event handler.
- The test runs this over fixture payload types: every leaf type, optionals, nested structs, arrays and maps, enums, and the DeterministicMath types.

The tests cover the router's two inline decode sequences by calling the same functions in the same order. If review would rather test the router's exact code, step 2 extracts each sequence into a `static func` on the router, and the tests call that. The extraction moves no work and adds none per frame.

## Harness

- **Generator.** SplitMix64 from a printed seed, the pattern in `SyncTableDiffTests`. Every input derives from `(seed, target, iteration)`, so a failure replays from those three numbers.
- **Corpus (seeds).** Two sources:
  - Client frames recorded from the TS SDK's encoder, which is the real client: join, action, client event and sync ack, in the three encodings. They go in `Tests/SwiftStateTreeTransportTests/Fixtures/ClientFrames/client-frames.json`. A vitest case re-encodes the frames and compares, so the fixture fails loudly when the SDK's frames change. A script regenerates it.
  - The action and client-event frames of `Fixtures/PayloadFrames/payload-frames.json`. These are already recorded from the server encoders, in all three encodings.
- **Mutators.** Each iteration applies 1 to 4 of these. Pure random bytes are also generated.
  - Byte mutations: a bit flip; a byte set to a boundary value (`0x00`, `0x7f`, `0x80`, `0xff`); a truncation; a range inserted, deleted or duplicated; two corpus entries spliced.
  - MessagePack mutations: a type marker swapped; a length or count header set to its maximum; a str/bin/ext header pointed past the end.
  - JSON token mutations:
    - a number replaced by a huge, negative or fractional one, or by `1e309`;
    - a lone surrogate escape (`\ud800`);
    - a field's value wrapped in nesting;
    - a key duplicated.
- **Oracle.** A decode passes if it returns or throws, and any thrown error counts. A trap ends the test process, which fails CI's job. To find the crasher, the long run writes each input to `SST_FUZZ_LAST_INPUT` before decoding it. Every suite has a `.timeLimit`, so a hang fails as a time-out.
- **Amplification.** One test decodes worst-case frames at the inbound limit, `maxFrameSize` (16 MiB): empty maps, one-byte values, the deepest nesting allowed.
  - It records the decoded element count and the time.
  - It asserts only that the count stays linear in the input size.
  - The numbers go in the PR, so review can decide whether a decoded-element budget is needed (#528's question). This change doesn't add one.
- **Budget.**
  - CI runs 2,000 iterations per target and encoding. The aim is under 10 s for the whole suite in a debug build. If the measured time is over, I lower the count, not raise the time limit.
  - The long run takes `SST_FUZZ_ITERATIONS` and `SST_FUZZ_SEED`. The default seed is fixed; `SST_FUZZ_SEED=random` picks one and prints it.
- **libFuzzer: not used.**
  - `-sanitize=fuzzer` needs a separate executable target per entry point, each with its own `main`, in a SwiftPM product that CI's build would then have to compile or skip.
  - What it adds is coverage feedback, and these decoders are small, structured and well seeded.
  - If the long run stops finding anything while coverage is still missing, a follow-up issue can revisit it. Nothing here blocks adding it later, because the entry points are plain functions over `Data`.

## Depth (#362)

T7 measures first: the deepest value each chain survives on a cooperative-pool thread in a debug build, up to the parser limits (JSON 512, MessagePack 64).
- **If every chain survives 512:** the test stays as a regression guard, and #362 closes with the numbers.
- **If not:** a nesting cap goes in before the recursive walk, the way `messagePackMaxNestingDepth` caps the unpacker, with a test that crashes on the uncapped code. There are two ways to cap; the measurement decides:
  - A byte scan of brackets outside strings in the JSON paths. This is an O(n) pass over every inbound JSON frame, on the decode path, so I'd flag it for an A/B before merge.
  - A cap inside `AnyCodable.init(from:)`, with a depth counter carried in the decoder's `userInfo`. It costs nothing on shallow frames.

## Findings

- A small fix (a throwing conversion in place of a trap, a missing bounds check) goes in the same PR. Its crasher becomes a fixture in a regression test.
- Anything larger gets its own issue, linked from the PR, with the crasher recorded. The fuzz case is marked `withKnownIssue` until the fix lands.

## Steps

1. The harness: generator, mutators and oracle. The corpus fixture from the TS SDK, with its vitest check.
2. T1–T4 (the frame decoders), and T6.
3. T5 (payload types), then T7 (depth) and the amplification test.
4. Fix or file what the fuzzing finds. Add a lesson entry if a finding carries one.
5. The PR.
   - Verification: full `swift test` in both sync modes, and `npm test` in `sdk/ts`.
   - Mutants:
     - (a) Replace a `throw` in `OpcodeTransportMessageDecoder.intValue` with a force cast. It must crash the suite.
     - (b) Remove the MessagePack count-versus-bytes check. It must fail the amplification test or crash.
     - (c) Inject an infinite loop into a target. Its `.timeLimit` must time it out.
   - The long run: 10^6 iterations per target on Linux with the pinned toolchain, with its seed and duration reported.

## Hot path

None expected: the harness is test-only. Two possible changes would touch the decode path; if either lands, the PR says so for an A/B:
- the router extraction, which only moves work and adds none;
- a #362 JSON nesting cap.
