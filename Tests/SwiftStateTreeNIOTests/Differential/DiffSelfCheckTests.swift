// Tests/SwiftStateTreeNIOTests/Differential/DiffSelfCheckTests.swift
//
// Checks of the harness itself (#555, plan §7): the comparator reports every transform of one
// side (c); a golden whose decoded view isn't its bytes is corrupt, and a record whose bytes
// differ while no field does fails (d); the scenario set is well formed (cell rule, names,
// vacuity) (g). Determinism (a) is the recorder's five processes; the mutants (b, f) are run by
// hand, with their output in the PR.

#if DEBUG
import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport
@testable import SwiftStateTreeNIO
import SwiftStateTreeTestSupport

extension DifferentialHarness {
    @Suite("Differential harness self-checks (#555)", .resolverDeadlinesOff)
    struct DiffSelfCheckTests {
        /// One real run, the transforms' base: two players, so frames, events and a close exist.
        private func baseRun() async throws -> DiffRunResult {
            let scenario = try #require(diffScenarios.first { $0.name == "two-players" })
            return try await runChecked(scenario, DiffCell(sync: .inTurn, encoding: .json, land: .tickless))
        }

        @Test("The comparator reports a dropped frame, a swap, a changed close, a dropped record entry")
        func comparatorIsStrict() async throws {
            let base = try await baseRun()
            #expect(DiffCompare.differences(base, base).isEmpty)

            let name = try #require(base.terminal.connections.keys.sorted().first)
            var connection = try #require(base.terminal.connections[name])
            try #require(connection.frames.count >= 2)

            var dropped = base
            connection.frames.removeLast()
            dropped.terminal.connections[name] = connection
            #expect(DiffCompare.differences(base, dropped).contains { $0.channel == .frames && $0.place == name })

            var swapped = base
            var frames = try #require(base.terminal.connections[name]).frames
            let pair = try #require(frames.indices.dropLast().first { frames[$0] != frames[$0 + 1] })
            frames.swapAt(pair, pair + 1)
            swapped.terminal.connections[name]?.frames = frames
            #expect(DiffCompare.differences(base, swapped).contains { $0.channel == .frames && $0.place == name })

            // The swap changes two frames: each is its own difference, so an expected difference
            // for the first can't cover the second. With bytes compared, each names both digests.
            let swappedFrames = DiffCompare.differences(base, swapped).filter {
                $0.checkpoint == "terminal" && $0.channel == .frames && $0.place == name
            }
            #expect(swappedFrames.count == 2, "\(swappedFrames)")
            #expect(swappedFrames.allSatisfy { $0.digests?.hasPrefix("fnv64:") == true })
            if let first = swappedFrames.first {
                let entry = DiffExpectedDifference(
                    scenario: "two-players", cell: DiffCell(sync: .inTurn, encoding: .json, land: .tickless),
                    checkpoint: first.checkpoint, channel: first.channel, place: first.place,
                    detail: first.detail, digests: first.digests, reason: "self-check"
                )
                let judged = DiffBranchLists.judge(swappedFrames, entries: [entry])
                #expect(judged.unexpected.count == 1 && judged.stale.isEmpty)
                // Other bytes with the same decoded frame don't match the entry.
                var otherBytes = first
                otherBytes.digests = "fnv64:0000000000000000 vs fnv64:0000000000000000"
                #expect(!entry.matches(otherBytes))
                // A decoded-only run matches the entry without its digests.
                let decoded = DiffCompare.differences(base, swapped, checkBytes: false).filter {
                    $0.checkpoint == "terminal" && $0.channel == .frames && $0.place == name
                }
                #expect(decoded.count == 2 && decoded.allSatisfy { $0.digests == nil })
                let decodedJudged = DiffBranchLists.judge(decoded, entries: [entry], checkBytes: false)
                #expect(decodedJudged.unexpected.count == 1 && decodedJudged.stale.isEmpty)
            }

            var closed = base
            closed.terminal.connections[name]?.close = DiffClose(code: 4999, reason: "mutated")
            #expect(DiffCompare.differences(base, closed).contains { $0.channel == .close && $0.place == name })

            // A note is compared: a changed value, a missing one and an extra one each differ.
            var noted = base
            noted.live.notes = ["a note": .bool(true)]
            var flipped = noted
            flipped.live.notes = ["a note": .bool(false)]
            #expect(DiffCompare.differences(noted, flipped).contains { $0.channel == .note && $0.place == "a note" })
            #expect(DiffCompare.differences(noted, base).contains { $0.channel == .note && $0.place == "a note" })
            #expect(DiffCompare.differences(base, noted).contains { $0.channel == .note && $0.place == "a note" })

            var recordDropped = base
            guard case .object(var root) = base.record.decoded, case .array(var recordFrames)? = root["frames"] else {
                Issue.record("the record has no frames")
                return
            }
            recordFrames.removeLast()
            root["frames"] = .array(recordFrames)
            recordDropped.record = DiffRecordCapture(bytes: base.record.bytes + Data([0]), decoded: .object(root), complete: true)
            // Byte mode: the bytes difference with its digests, and the field paths beside it.
            let byBytes = DiffCompare.differences(base, recordDropped).filter { $0.channel == .record }
            #expect(byBytes.contains { $0.place == DiffCompare.recordBytesPlace && $0.digests != nil })
            #expect(byBytes.contains { $0.place != DiffCompare.recordBytesPlace })
            // Decoded views only (another toolchain): the field paths, no bytes difference.
            let byFields = DiffCompare.differences(base, recordDropped, checkBytes: false).filter { $0.channel == .record }
            #expect(!byFields.isEmpty && byFields.allSatisfy { $0.place != DiffCompare.recordBytesPlace && $0.digests == nil })
        }

        @Test("Record bytes that differ while no field does fail; decoded-only comparison skips them")
        func recordBytesWithoutAField() async throws {
            let base = try await baseRun()
            var changed = base
            changed.record = DiffRecordCapture(bytes: base.record.bytes + Data([0]), decoded: base.record.decoded, complete: base.record.complete)
            #expect(DiffCompare.differences(base, changed).map(\.place) == ["<bytes>"])
            #expect(DiffCompare.differences(base, changed, checkBytes: false).isEmpty)
        }

        @Test("A JSON payload's spelling differs only in the bytes; a changed payload value is reported at its path in both modes")
        func jsonRecordPayloadComparesAsTreeOffThePinnedToolchain() async throws {
            /// A saved record of one action whose payload is `payloadJSON`'s bytes.
            func capture(_ payloadJSON: String) async throws -> DiffRecordCapture {
                let recorder = ReevaluationRecorder()
                await recorder.setMetadata(ReevaluationRecordMetadata(
                    landID: "self-check:1", landType: "self-check", createdAt: Date(timeIntervalSince1970: 0), metadata: [:]
                ))
                await recorder.record(tickId: 0, actions: [ReevaluationRecordedAction(
                    kind: "action", sequence: 0, typeIdentifier: "SelfCheckAction",
                    payload: Data(payloadJSON.utf8), payloadEncoding: .json,
                    playerID: "p", clientID: "c", sessionID: "s", resolverOutputs: [:], resolvedAtTick: 0
                )], clientEvents: [], lifecycleEvents: [])
                let path = FileManager.default.temporaryDirectory.appendingPathComponent("self-check-\(UUID().uuidString).sstr").path
                defer { try? FileManager.default.removeItem(atPath: path) }
                try await recorder.save(to: path)
                let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
                let contents = try ReevaluationRecordLog.decodeForTesting(Array(bytes))
                #expect(contents.frames.count == 1)
                return DiffRecordCapture(bytes: bytes, decoded: try DiffRun.decodedView(contents), complete: true)
            }
            let escaped = try await capture(#"{"k":"a\/b"}"#)
            let plain = try await capture(#"{"k":"a/b"}"#)
            #expect(escaped.decoded == plain.decoded, "the view holds the tree, not the spelling")
            #expect(DiffCompare.compareRecord(escaped, plain, checkBytes: true).map(\.place) == [DiffCompare.recordBytesPlace])
            #expect(DiffCompare.compareRecord(escaped, plain, checkBytes: false).isEmpty)

            let changed = try await capture(#"{"k":"c"}"#)
            let path = "frames[0].actions[0].payload.k"
            #expect(DiffCompare.compareRecord(plain, changed, checkBytes: true).map(\.place) == [DiffCompare.recordBytesPlace, path])
            #expect(DiffCompare.compareRecord(plain, changed, checkBytes: false).map(\.place) == [path])
        }

        @Test("A recorded payload that isn't base64 in the record view fails the run")
        func nonBase64PayloadFailsTheView() throws {
            let view = DiffValue.object(["frames": .array([.object(["actions": .array([
                .object(["payload": .string("not base64!"), "sequence": .int(0)]),
            ])])])])
            #expect(throws: DiffRunFailure.self) { _ = try DiffRun.payloadsAsTrees(view) }
        }

        @Test("A server input's bytes are shown as their MessagePack tree, under a JSON header too")
        func serverInputPayloadIsAMessagePackTreeInTheView() async throws {
            /// A saved record, with no header encoding (`json`), of one server input whose bytes
            /// are `payload`'s canonical MessagePack.
            func view(_ payload: [String: Any]) async throws -> DiffValue {
                let recorder = ReevaluationRecorder()
                await recorder.setMetadata(ReevaluationRecordMetadata(
                    landID: "self-check:1", landType: "self-check", createdAt: Date(timeIntervalSince1970: 0), metadata: [:]
                ))
                let bytes = Data(try CanonicalMessagePack.encode(AnyCodable(payload)))
                await recorder.record(
                    tickId: 0, actions: [], clientEvents: [], lifecycleEvents: [],
                    serverInputs: [ReevaluationRecordedServerInput(sequence: 0, typeIdentifier: "SelfCheckInput", payload: bytes, resolvedAtTick: 0)]
                )
                let path = FileManager.default.temporaryDirectory.appendingPathComponent("self-check-\(UUID().uuidString).sstr").path
                defer { try? FileManager.default.removeItem(atPath: path) }
                try await recorder.save(to: path)
                let contents = try ReevaluationRecordLog.decodeForTesting(Array(try Data(contentsOf: URL(fileURLWithPath: path))))
                return try DiffRun.decodedView(contents)
            }
            let shown = try await view(["k": "v"])
            guard case .object(let root) = shown, case .array(let frames)? = root["frames"],
                  case .object(let frame)? = frames.first, case .array(let inputs)? = frame["serverInputs"],
                  case .object(let input)? = inputs.first else {
                Issue.record("no server input in the view: \(DiffValue.canonicalText(shown))")
                return
            }
            #expect(input["payload"] == .object(["k": .string("v")]))
            var paths: [(String, String)] = []
            DiffCompare.walk(shown, try await view(["k": "w"]), path: "", into: &paths)
            #expect(paths.map(\.0) == ["frames[0].serverInputs[0].payload.k"])
            // Nested past a client payload's limit (32) and within a server input's: the view reads
            // it with the record codec, as replay does.
            var deep: Any = 1
            for _ in 0..<60 { deep = [deep] }
            _ = try await view(["k": deep])
        }

        @Test("A golden whose decoded view isn't its bytes is corrupt")
        func corruptGolden() async throws {
            let base = try await baseRun()
            #expect(DiffGolden.corruption(of: base) == nil)

            let name = try #require(base.terminal.connections.keys.sorted().first)
            var frame = try #require(base.terminal.connections[name]?.frames.first)
            frame = try DiffFrame(bytes: frame.bytes, decodedOverride: .string("edited"))
            var edited = base
            edited.terminal.connections[name]?.frames[0] = frame
            #expect(DiffGolden.corruption(of: edited) != nil, "an edited frame view")

            var record = base
            record.record = DiffRecordCapture(bytes: base.record.bytes, decoded: .string("edited"), complete: base.record.complete)
            #expect(DiffGolden.corruption(of: record) != nil, "an edited record view")
        }

        // Two tests, not one with arguments: the gate script names each test `name()` in the
        // results, which a parameterized test's `name(land:)` doesn't match.
        @Test("The harness waits for the writer's sync-cycle drain before the tick land's tick (#917)")
        func harnessTickWaitsForTheWriter() async throws {
            try await harnessSyncWaitsForTheWriter(land: .tick)
        }

        @Test("The harness waits for the writer's sync-cycle drain before the tickless land's sync (#917)")
        func harnessSyncWaitsForTheWriter() async throws {
            try await harnessSyncWaitsForTheWriter(land: .tickless)
        }

        private func harnessSyncWaitsForTheWriter(land: DiffLandKind) async throws {
            // The writer can't be held from here: the transport's `send` hands each frame to its
            // connection in a task, so the writer's element retires before any connection-level
            // gate. The harness's own seam is the drain observer, called by each drain it waits
            // for, before the wait. (A drain that calls the observer and skips the wait passes
            // this check; only the sweep's deferral count, which depends on timing, would see it.)
            let seen = DrainObservation()
            let site: DiffDrainSite = land == .tick ? .tick : .beforeSync
            let scenario = DiffScenario(
                name: "self-check-writer-drain",
                cells: .all,
                steps: [
                    .connect("A", session: "s-a"),
                    .join("A", player: "pa"),
                    .bumpUnsynced("A", requestID: "bump-a", amount: 1),
                    .tickUnsynced,
                    .check("the next drain is observed") { run in
                        let deferred = await run.adapter.syncSkipCounts().outboundBacklog
                        let outputs = await run.adapter.syncOutputDigestCountForTesting
                        run.drainObserverForTesting = { run, reached in
                            guard reached == site, !seen.recorded else { return }
                            // Nothing of the next step has run yet: no phase was deferred, and no
                            // phase planned an output (the count moves inside the phase, in the
                            // keeper's turn, so this doesn't depend on the writer's timing).
                            seen.record(
                                deferredSince: await run.adapter.syncSkipCounts().outboundBacklog - deferred,
                                outputsSince: await run.adapter.syncOutputDigestCountForTesting - outputs
                            )
                        }
                    },
                    // The step that runs a sync (and on a tick land, a tick first).
                    land == .tick ? .tick : .settleJobs,
                    .liveCheckpoint,
                ],
                outcomes: [:],
                lifecycle: ["pa": [.join, .leave]]
            )
            let cell = DiffCell(sync: .inTurn, encoding: .json, land: land)
            let result = try await DiffRun.make(scenario, cell: cell).execute()
            let observed = try #require(seen.value, "the step ran no writer drain at \(site)")
            #expect(observed.deferredSince == 0 && observed.outputsSince == 0, "the step's phase ran before the drain: \(observed)")
            #expect(result.diagnostics.syncPhasesDeferredByBackPressure == 0, "\(result.diagnostics.summary)")
            // And the step's sync delivered the bump afterwards.
            let frames = try #require(result.live.connections["A"]?.frames)
            #expect(frames.contains { DiffValue.canonicalText($0.decoded).contains("\"/counter\"") }, "A never got the bump's update")
        }

        @Test("A finished run releases its keeper's recorder, which deletes its spool file (#910)", arguments: DiffLandKind.allCases)
        func aFinishedRunReleasesItsRecorder(land: DiffLandKind) async throws {
            // second-session reaches both drain sites (a kick's keeper leave and a join's sync
            // request), whose hold bodies are the ones the keeper holds.
            let scenario = try #require(diffScenarios.first { $0.name == "second-session" })
            weak var recorder: ReevaluationRecorder?
            var spool: String?
            do {
                let run = try await DiffRun.make(scenario, cell: DiffCell(sync: .inTurn, encoding: .json, land: land))
                recorder = run.recorder
                spool = await run.recorder.getSpoolPath()
                _ = try await run.execute()
            }
            let path = try #require(spool)
            let deadline = ContinuousClock.now + testHangBound
            while recorder != nil || FileManager.default.fileExists(atPath: path) {
                guard ContinuousClock.now < deadline else { break } // wall-clock: the hang bound of this poll, never reached by a passing run
                try await Task.sleep(for: .milliseconds(10)) // wall-clock: a deinit, and the file removal on the writer's queue, have no event the test can await; a passing run leaves at once
            }
            #expect(recorder == nil, "the run's recorder outlived the run")
            #expect(!FileManager.default.fileExists(atPath: path), "the run left its spool file: \(path)")
        }

        @Test("A kick's leave and a join's sync request wait for the writer's drain too (#917)")
        func keeperPhasesWaitForTheWriter() async throws {
            // second-session: A2's join kicks A (a keeper leave), then asks for A2's join sync turn.
            let scenario = try #require(diffScenarios.first { $0.name == "second-session" })
            let events = DrainEvents()
            let run = try await DiffRun.make(scenario, cell: DiffCell(sync: .inTurn, encoding: .json, land: .tickless))
            // The observer lives on this run only, and goes with it.
            run.drainObserverForTesting = { _, site in events.append("drain \(site)") }
            // Registered after `make`, as a scenario's armed hold is: it must run after the
            // harness's body at the same point (HoldRegistry runs a point's bodies in
            // registration order, one after another), so the writer has drained when it runs.
            let writer = await run.adapter.outboundWriter
            run.holds.keeper.on(.leave) {
                events.append("scenario leave, writer drained: \(writer.backlog.syncCycleElements == 0)")
            }
            run.holds.adapter.on(.joinSyncRequested) {
                events.append("scenario joinSync, writer drained: \(writer.backlog.syncCycleElements == 0)")
            }
            let result = try await run.execute()
            let all = events.all
            let leaves = all.indices.filter { all[$0].hasPrefix("scenario leave") }
            let joinSyncs = all.indices.filter { all[$0].hasPrefix("scenario joinSync") }
            #expect(!leaves.isEmpty && !joinSyncs.isEmpty, "\(all)")
            for index in leaves {
                #expect(index > 0 && all[index - 1] == "drain keeperLeave", "\(all)")
                #expect(all[index].hasSuffix("true"), "\(all)")
            }
            for index in joinSyncs {
                #expect(index > 0 && all[index - 1] == "drain joinSyncRequest", "\(all)")
                #expect(all[index].hasSuffix("true"), "\(all)")
            }
            #expect(result.diagnostics.syncPhasesDeferredByBackPressure == 0, "\(result.diagnostics.summary)")
        }

        @Test("The sweep flags a deferral outside the forcing scenario, and a forcing scenario without one (#917)")
        func sweepChecksDeferrals() async throws {
            let base = try await baseRun()
            let forcing = try #require(diffScenarios.first { $0.name == "join-during-writer-backlog" })
            let other = try #require(diffScenarios.first { $0.name == "two-players" })
            #expect(DiffSweep.scenariosForcingBackPressure == [forcing.name])
            func sweep(forcing forcingCount: Int, other otherCount: Int) async -> DiffSweep.Report {
                await DiffSweep.run(
                    scenarios: [forcing, other], retired: [], expected: [], toolchain: "self-check",
                    execute: { scenario, _ in
                        var result = base
                        result.diagnostics.syncPhasesDeferredByBackPressure = scenario.name == forcing.name ? forcingCount : otherCount
                        return result
                    },
                    readGolden: { name in
                        DiffGoldenFile(
                            scenario: name, cell: "",
                            recordedWith: DiffRecordedWith(commit: "self-check", toolchain: "self-check"),
                            result: base
                        )
                    }
                )
            }
            let clean = await sweep(forcing: 1, other: 0)
            #expect(clean.issues.isEmpty, "\(clean.issues)")

            let flagged = await sweep(forcing: 0, other: 1)
            let forcingCells = forcing.cells.cells.count, otherCells = other.cells.cells.count
            let stopped = flagged.issues.filter { $0.contains("no sync phase was deferred, in a scenario that forces") }
            let stray = flagged.issues.filter { $0.contains("in a scenario that doesn't force the writer's back-pressure") }
            #expect(stopped.count == forcingCells && stopped.allSatisfy { $0.hasPrefix(forcing.name) }, "\(flagged.issues)")
            #expect(stray.count == otherCells && stray.allSatisfy { $0.hasPrefix(other.name) }, "\(flagged.issues)")
            #expect(flagged.issues.count == forcingCells + otherCells, "\(flagged.issues)")
        }

        @Test("A cell that throws is reported, and the sweep still compares and reports every later cell")
        func sweepGoesOnAfterAThrow() async throws {
            let base = try await baseRun()
            let throwing = try #require(diffScenarios.first { $0.name == "join-act-leave" })
            let differing = try #require(diffScenarios.first { $0.name == "two-players" })
            // The later scenario's golden misses a frame its run has.
            var golden = base
            let connection = try #require(golden.terminal.connections.keys.sorted().first)
            var frames = try #require(golden.terminal.connections[connection]).frames
            try #require(!frames.isEmpty)
            frames.removeLast()
            golden.terminal.connections[connection]?.frames = frames
            let report = await DiffSweep.run(
                scenarios: [throwing, differing],
                retired: [],
                expected: [],
                toolchain: "self-check",
                execute: { scenario, _ in
                    if scenario.name == throwing.name { throw DiffRunFailure("forced") }
                    return base
                },
                readGolden: { name in
                    DiffGoldenFile(
                        scenario: name, cell: "",
                        recordedWith: DiffRecordedWith(commit: "self-check", toolchain: "self-check"),
                        result: golden
                    )
                }
            )
            let thrown = throwing.cells.cells.count
            let compared = differing.cells.cells.count
            #expect(report.ran == thrown + compared, "every cell ran: \(report.ran)")
            #expect(report.threw.count == thrown)
            #expect(report.threw.allSatisfy { $0.hasPrefix("\(throwing.name) ") })
            // Each thrown cell is an issue of its own: the suite records issues, so this is what
            // makes a thrown cell fail the harness.
            #expect(report.issues.filter { $0.hasPrefix("\(throwing.name) ") }.count == thrown)
            #expect(report.compared == compared)
            let reported = report.issues.filter { $0.hasPrefix("\(differing.name).") }
            #expect(reported.count == compared, "every later cell's difference is reported: \(report.issues)")
        }

        @Test("An update under the verify key is refused")
        func updateUnderVerify() {
            #expect(DiffGolden.updateRefusal(environment: [DiffGoldenKeys.update: "1", DiffGoldenKeys.verify: "1"]) != nil)
            #expect(DiffGolden.updateRefusal(environment: [DiffGoldenKeys.update: "1"]) == nil)
            #expect(DiffGolden.updateRefusal(environment: [DiffGoldenKeys.verify: "1"]) == nil)
        }

        @Test("The branch lists: exact, one use, stale and overlap fail, retired keys exact")
        func branchListRules() {
            let cell = DiffCell(sync: .inTurn, encoding: .json, land: .tickless)
            let index = ["two-players.\(cell).json", "join-act-leave.\(cell).json"]
            let difference = DiffDifference(checkpoint: "terminal", channel: .frames, place: "A", detail: "frame 3 differs")
            func entry(_ detail: String = "frame 3 differs", scenario: String = "two-players") -> DiffExpectedDifference {
                DiffExpectedDifference(scenario: scenario, cell: cell, checkpoint: "terminal", channel: .frames, place: "A", detail: detail, reason: "test")
            }
            // Exact match, used once.
            var judged = DiffBranchLists.judge([difference], entries: [entry()])
            #expect(judged.unexpected.isEmpty && judged.stale.isEmpty)
            // A near match covers nothing: the difference is unexpected and the entry stale.
            judged = DiffBranchLists.judge([difference], entries: [entry("frame 4 differs")])
            #expect(judged.unexpected.count == 1 && judged.stale.count == 1)
            // One entry covers one difference, not two.
            judged = DiffBranchLists.judge([difference, difference], entries: [entry()])
            #expect(judged.unexpected.count == 1 && judged.stale.isEmpty)
            // An unused entry is stale.
            #expect(DiffBranchLists.judge([], entries: [entry()]).stale.count == 1)
            // Overlap, a key outside the index, a retired key twice, a retired key outside the index,
            // and an expected difference on a retired cell.
            #expect(DiffBranchLists.problems(expected: [entry(), entry()], retired: [], indexFiles: index).count == 1)
            #expect(DiffBranchLists.problems(expected: [entry(scenario: "nope")], retired: [], indexFiles: index).count == 1)
            let row = DiffRetiredRow(scenario: "join-act-leave", cells: [cell, cell], reason: "test", witness: "w", replacement: {})
            #expect(DiffBranchLists.problems(expected: [], retired: [row], indexFiles: index).count == 1)
            let outside = DiffRetiredRow(scenario: "nope", cells: [cell], reason: "test", witness: "w", replacement: {})
            #expect(DiffBranchLists.problems(expected: [], retired: [outside], indexFiles: index).count == 1)
            let retiredTwoPlayers = DiffRetiredRow(scenario: "two-players", cells: [cell], reason: "test", witness: "w", replacement: {})
            #expect(DiffBranchLists.problems(expected: [entry()], retired: [retiredTwoPlayers], indexFiles: index).count == 1)
            let noWitness = DiffRetiredRow(scenario: "two-players", cells: [cell], reason: "test", witness: "", replacement: {})
            #expect(DiffBranchLists.problems(expected: [], retired: [noWitness], indexFiles: index).count == 1)
            // The lists on main are empty. Judged only where the protected workflow says the lists
            // are main's (`SST_DIFFERENTIAL_MAIN_LISTS=1`): the rewrite branch's PR fills them.
            if EnvHelpers.getEnvBool(key: DiffBranchLists.mainListsKey, defaultValue: false) {
                #expect(diffExpectedDifferences.isEmpty && diffRetiredRows.isEmpty, "main's lists aren't empty")
            }
        }

        @Test("Every scenario has cells, a unique name, a live checkpoint, and states its requests")
        func scenariosAreWellFormed() {
            var names = Set<String>()
            for scenario in diffScenarios {
                #expect(!scenario.cells.cells.isEmpty, "\(scenario.name) has no cells")
                #expect(names.insert(scenario.name).inserted, "\(scenario.name) is named twice")
                let checkpoints = scenario.steps.filter { if case .liveCheckpoint = $0 { return true } else { return false } }
                #expect(checkpoints.count == 1, "\(scenario.name) has \(checkpoints.count) live checkpoints")
                #expect(!scenario.outcomes.isEmpty, "\(scenario.name) states no request")
                #expect(!scenario.lifecycle.isEmpty, "\(scenario.name) states no lifecycle")
            }
            // A recorded outcome makes no claim, so each use is listed here, with its issue: one
            // can't be added without this list changing (and the PR that adds it listing it).
            var recorded: [String] = []
            for scenario in diffScenarios {
                for cell in scenario.cells.cells {
                    for (id, outcome) in scenario.outcomes(in: cell) {
                        if case .recorded(let issue) = outcome {
                            #expect(DiffOutcome.isIssueReference(issue), "\(scenario.name) \(id): \"\(issue)\" isn't an issue reference")
                            recorded.append("\(scenario.name) \(id) \(issue)")
                        }
                    }
                }
            }
            #expect(Set(recorded) == ["teardown-during-keeper-join join-A #548"], "recorded outcomes: \(Set(recorded).sorted())")
            let lifecycles = diffScenarios.flatMap { scenario in
                scenario.recordedLifecycle.map { "\(scenario.name) \($0.key) \($0.value)" }
            }
            #expect(Set(lifecycles) == ["teardown-during-keeper-join pa #548"], "recorded lifecycles: \(Set(lifecycles).sorted())")
        }

        @Test("A run reports the sync phases the writer's back-pressure deferred, outside the comparison (#908)")
        func runReportsBackPressureDeferrals() async throws {
            let scenario = try #require(diffScenarios.first { $0.name == "second-session" })
            let cell = DiffCell(sync: .inTurn, encoding: .json, land: .tickless)
            let quiet = try await DiffRun.make(scenario, cell: cell).execute()
            #expect(quiet.diagnostics.syncPhasesDeferredByBackPressure == 0)
            #expect(quiet.diagnostics.summary.isEmpty)

            // One deferral: the first join's sync turn finds the writer busy once.
            let run = try await DiffRun.make(scenario, cell: cell)
            let busy = OneBusyRead()
            _ = run.holds.adapter.on(.joinSyncRequested, arrival: 1) { busy.arm() }
            await run.adapter.setWriterBackPressureOverrideForTesting { busy.take() }
            let deferred = try await run.execute()
            #expect(deferred.diagnostics.syncPhasesDeferredByBackPressure == 1)
            #expect(deferred.diagnostics.summary == "sync phases deferred by the writer's back-pressure: 1")
            // Not part of the result's identity, and not in its encoding.
            var copy = quiet
            copy.diagnostics = deferred.diagnostics
            #expect(copy == quiet)
            let encoded = String(decoding: try JSONEncoder().encode(copy), as: UTF8.self)
            #expect(!encoded.contains("diagnostics"))
        }
    }
}

/// What the harness's drain observer saw, once.
private final class DrainObservation: @unchecked Sendable {
    struct Value: CustomStringConvertible {
        let deferredSince: Int
        let outputsSince: Int
        var description: String { "deferred since \(deferredSince), outputs since \(outputsSince)" }
    }
    private let lock = NSLock()
    private var stored: Value?
    var value: Value? { lock.withLock { stored } }
    var recorded: Bool { value != nil }
    func record(deferredSince: Int, outputsSince: Int) {
        lock.withLock { if stored == nil { stored = Value(deferredSince: deferredSince, outputsSince: outputsSince) } }
    }
}

/// What ran at the harness's drains and at a scenario's holds, in order.
private final class DrainEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    var all: [String] { lock.withLock { events } }
    func append(_ event: String) { lock.withLock { events.append(event) } }
}

/// A writer that reads busy once after `arm()`.
private final class OneBusyRead: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    func arm() { lock.withLock { armed = true } }
    func take() -> Bool { lock.withLock { defer { armed = false }; return armed } }
}
#endif
