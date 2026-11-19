// The documentation's "without the framework" comparison (WithoutTheFramework.md): the lobby as
// a plain actor, as a plain actor fixed by hand with a generation ticket, and on the turn core
// (WorkedExampleTests.swift). One scenario, forced with a hold at the load's `await`, never with
// timing: a player joins, the profile load is held, the player leaves, the load returns.

import SwiftStateTree
import SwiftStateTurns
import Testing

// docs:naive
/// A plain actor: check, await, write.
actor NaiveLobby {
    let profiles: any ProfileStore
    private(set) var seats: [Int: String] = [:]

    init(profiles: any ProfileStore) {
        self.profiles = profiles
    }

    func join(_ player: Int) async -> Int {
        guard seats[player] == nil else { return seats.count }
        let name = await profiles.load(player)
        // Other calls ran during the await: the player may have left. This write doesn't know.
        seats[player] = name
        return seats.count
    }

    func leave(_ player: Int) {
        seats[player] = nil
    }
}
// docs:end

// docs:ticketed
/// The same actor, fixed by hand: a ticket captured before the await, checked after it.
actor TicketedLobby {
    let profiles: any ProfileStore
    private(set) var seats: [Int: String] = [:]
    private var joins = GenerationTable<Int>()

    init(profiles: any ProfileStore) {
        self.profiles = profiles
    }

    func join(_ player: Int) async throws -> Int {
        guard seats[player] == nil else { return seats.count }
        let ticket = joins.issue(player)
        let name = await profiles.load(player)
        // Still this join's generation? `ifCurrent`'s closure can't await, so the check and the
        // write are one synchronous segment.
        guard joins.ifCurrent(ticket, { _ in seats[player] = name }) != nil else {
            throw LobbyError.left
        }
        return seats.count
    }

    func leave(_ player: Int) {
        joins.end(player)
        seats[player] = nil
    }
}
// docs:end

/// A store whose load waits until the test releases it: the hold at the `await`.
struct HeldProfiles: ProfileStore {
    let fixture: Fixture

    func load(_ player: Int) async -> String {
        fixture.open("loading \(player)")
        await fixture.wait("release \(player)")
        return "player \(player)"
    }
}

@Suite("The documentation's comparison: a leave during a join's load", .timeLimit(.minutes(1)))
struct ComparisonTests {
    @Test("A plain actor seats a player who already left (the hazard, shown on purpose)")
    func naiveSeatsAGhost() async {
        let f = Fixture()
        let lobby = NaiveLobby(profiles: HeldProfiles(fixture: f))
        let join = Task { await lobby.join(7) }
        await f.wait("loading 7")
        await lobby.leave(7)
        f.open("release 7")
        let count = await join.value
        // The bug: the seat is written after the leave. This test documents it; it passes when
        // the bug happens.
        #expect(count == 1)
        #expect(await lobby.seats[7] == "player 7")
    }

    @Test("Fixed by hand: the ticket taken before the await is no longer current after the leave")
    func ticketedRefusesTheStaleWrite() async {
        let f = Fixture()
        let lobby = TicketedLobby(profiles: HeldProfiles(fixture: f))
        let join = Task { try await lobby.join(7) }
        await f.wait("loading 7")
        await lobby.leave(7)
        f.open("release 7")
        let result = await join.result
        #expect(throws: LobbyError.self) { try result.get() }
        #expect(await lobby.seats.isEmpty)
    }

    @Test("On the turn core: the leave ends the binding; the load's result is stale, and nothing is seated")
    func turnCoreNeedsNoTicket() async throws {
        let f = Fixture()
        let lobby = LobbyActor(profiles: HeldProfiles(fixture: f))
        let join = Task { try await lobby.sendAndWait(.join(player: 7), cancellation: .ignoresCancel) }
        await f.wait("loading 7")
        await lobby.send(.leave(player: 7))
        // The joiner is answered in the leave's batch, before the load returns.
        let result = await join.result
        f.open("release 7")
        // The load's result comes back as an input, and steps as stale (a condition, not a delay).
        for _ in 0 ..< 10_000 where await lobby.late() == 0 {
            await Task.yield() // wall-clock: not time: documented code carries no test hooks; yields until the late result has run
        }
        #expect(throws: LobbyError.self) { try result.get() }
        #expect(await lobby.late() == 1)
        #expect(await lobby.seats().isEmpty)
        #expect(await lobby.heldKeys() == 0)
    }
}
