// The worked example of the SwiftStateTurns documentation (WorkedExample.md, and the turn
// version in WithoutTheFramework.md), compiled and run here so it can't drift: every Swift block
// in the documentation must appear in this file, ComparisonTests.swift or ConceptsTests.swift
// (the last test here checks it).

import Foundation
import SwiftStateTurns
import Testing

// docs:store
/// Where profiles come from: a service in production, a held fake in a test.
protocol ProfileStore: Sendable {
    func load(_ player: Int) async -> String
}
// docs:end

// docs:machine
/// A lobby that loads a player's profile before seating them, one load at a time.
@PlainData
struct Lobby: TurnMachine {
    enum Input: Sendable {
        case join(player: Int)
        case loaded(player: Int, name: String)
        case leave(player: Int)
    }

    enum Effect: Sendable {
        case loadProfile(player: Int)
    }

    /// A player's binding, and the profile store, which one load holds at a time.
    enum Key: Hashable, Sendable {
        case player(Int)
        case store
    }

    typealias Output = String
    typealias Reply = Int

    var seats: [Int: String]
    var loading: [RequestID: Int]
    var waiting: [Int: InputID]
    /// Loads that came back after their join was given up.
    var late: Int
    /// How long one load may hold the store before its join is given up.
    var loadDeadline: Duration = .seconds(2)

    func inputPolicy(for input: Input) -> InputPolicy<Key> {
        switch input {
        // A join waits while another join's load holds the profile store.
        case .join: .normal(waitsFor: .store, belongsTo: nil)
        default: .normal(waitsFor: nil, belongsTo: nil)
        }
    }

    mutating func handle(_ input: Input, _ turn: inout Turn<Lobby>) {
        switch input {
        case .join(let player):
            // The player's binding. The load is a request it owns, holding the store with a
            // deadline.
            turn.start(.player(player))
            let hold = Hold.untilRequestCloses(Key.store, deadline: loadDeadline)
            guard let id = turn.request(.loadProfile(player: player), for: .player(player), holding: hold) else { return }
            loading[id] = player
            if let caller = turn.input { waiting[player] = caller }
        case .loaded(let player, let name):
            // The load's result, back as an input. It reaches `handle` only while its request
            // is open, so the player is still joining: the state changes here, in a step.
            loading = loading.filter { $0.value != player }
            seats[player] = name
            turn.emit("welcome \(name)", for: .player(player))
            if let caller = waiting.removeValue(forKey: player) {
                turn.reply(to: caller, .success(seats.count))
            }
        case .leave(let player):
            // Ends the binding: a load in flight is abandoned, and its late result is stale.
            turn.end(.player(player))
            seats[player] = nil
        }
    }

    mutating func handleAbandoned(_ request: RequestID, _ why: Abandonment, _ turn: inout Turn<Lobby>) {
        // The deadline passed, or the player left: the joiner is told, and the store is free.
        guard let player = loading.removeValue(forKey: request),
              let caller = waiting.removeValue(forKey: player) else { return }
        let error: LobbyError = why == .deadline ? .profileUnavailable : .left
        turn.reply(to: caller, .failure(error))
    }

    mutating func handleLateResult(_ input: Input, _ turn: inout Turn<Lobby>) {
        // A load that returned after its request closed: nothing to seat.
        late += 1
    }
}

enum LobbyError: Error {
    case profileUnavailable
    case left
}
// docs:end

// docs:actor
/// The actor that owns the lobby's core.
actor LobbyActor: TurnActor {
    let core: TurnCore<Lobby>
    nonisolated let profiles: any ProfileStore
    private(set) var sent: [String] = []

    init(profiles: any ProfileStore, loadDeadline: Duration = .seconds(2)) {
        self.profiles = profiles
        core = TurnCore(
            Lobby(seats: [:], loading: [:], waiting: [:], late: 0, loadDeadline: loadDeadline),
            queueLimit: 64,
            maxReleasesPerBatch: 16,
            clock: SystemTurnClock()
        )
    }

    /// The profile load, off the actor. Its result comes back as an input.
    @concurrent nonisolated func perform(_ effect: Lobby.Effect) async -> Lobby.Input? {
        switch effect {
        case .loadProfile(let player):
            return .loaded(player: player, name: await profiles.load(player))
        }
    }

    /// The step's outputs, between steps: here, a list; in a server, the sends.
    func flush(_ outputs: consuming [String]) {
        sent.append(contentsOf: outputs)
    }
}
// docs:end

/// A store that answers at once.
struct ImmediateProfiles: ProfileStore {
    func load(_ player: Int) async -> String { "player \(player)" }
}

extension LobbyActor {
    /// The test's view of the core, between steps.
    func heldKeys() -> Int { core.stats.heldKeys }
    func seats() -> [Int: String] { core.read { $0.seats } }
    func late() -> Int { core.read { $0.late } }
}

@Suite("The documentation's worked example")
struct WorkedExampleTests {
    @Test("The lobby: a call joins and waits for the loaded profile; a second join queues behind the first load")
    func lobby() async throws {
        try await withinTestHangBound {
            // docs:use
            let lobby = LobbyActor(profiles: ImmediateProfiles(), loadDeadline: .seconds(300))
            let count = try await lobby.sendAndWait(.join(player: 7), cancellation: .ignoresCancel)
            // count == 1, and the lobby flushed "welcome player 7".
            // docs:end
            // Outside the documented block, the test's own wait is bounded.
            let second = try await boundedResult {
                try await lobby.sendAndWait(.join(player: 8), cancellation: .ignoresCancel)
            }.get()
            #expect(count == 1)
            #expect(second == 2)
            #expect(await lobby.sent == ["welcome player 7", "welcome player 8"])
            #expect(await lobby.heldKeys() == 0)
        }
    }

    /// Every ```swift block of the documentation, in the DocC catalog and in docs/turns/: each
    /// must appear in this file, ComparisonTests.swift or ConceptsTests.swift, compared without
    /// leading whitespace (an article shows a block dedented).
    @Test("Every Swift block in the documentation appears in the tested files")
    func documentationMatchesTheTests() throws {
        let here = URL(fileURLWithPath: #filePath)
        let tests = here.deletingLastPathComponent()
        let root = tests.deletingLastPathComponent().deletingLastPathComponent()
        let catalog = root.appendingPathComponent("Sources/SwiftStateTurns/SwiftStateTurns.docc")
        let pages = try FileManager.default.contentsOfDirectory(atPath: catalog.path)
            .filter { $0.hasSuffix(".md") }
            .map { catalog.appendingPathComponent($0) }
            + ["README.md", "README.zh-TW.md"].map { root.appendingPathComponent("docs/turns/\($0)") }
        let source = try [here, tests.appendingPathComponent("ComparisonTests.swift"), tests.appendingPathComponent("ConceptsTests.swift")]
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        func flat(_ text: String) -> String {
            text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.drop { $0 == " " } }
                .joined(separator: "\n")
        }
        let flatSource = flat(source)
        var blocks = 0
        for page in pages {
            let text = try String(contentsOf: page, encoding: .utf8)
            for block in text.components(separatedBy: "```swift\n").dropFirst().map({ $0.components(separatedBy: "```")[0] }) {
                blocks += 1
                #expect(flatSource.contains(flat(block)), "\(page.lastPathComponent): not in the tested files:\n\(block)")
            }
        }
        #expect(blocks >= 20)
    }
}
