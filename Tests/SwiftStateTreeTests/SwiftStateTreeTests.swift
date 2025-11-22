// Tests/SwiftStateTreeTests/SwiftStateTreeTests.swift

import XCTest
@testable import SwiftStateTree

final class SwiftStateTreeTests: XCTestCase {

    func testJoinAndAttack() async throws {
        let room = RoomActor(roomID: "test")
        let alice = PlayerID("alice")
        let bob = PlayerID("bob")

        await room.handle(.join(playerID: alice, name: "Alice"))
        await room.handle(.join(playerID: bob, name: "Bob"))
        await room.handle(.attack(attacker: alice, target: bob, damage: 10))

        let snapshot = await room.snapshot()
        let bobState = snapshot.players[bob]
        XCTAssertEqual(bobState?.hp, 90)
    }
}

