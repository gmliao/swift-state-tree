// Sources/SwiftStateTreeVaporDemo/Routes.swift

import Vapor
import SwiftStateTree

func routes(_ app: Application) throws {

    app.get("health") { _ in
        "OK"
    }

    // WebSocket endpoint: /ws/:roomID/:playerID
    app.webSocket("ws", ":roomID", ":playerID") { req, ws in
        guard
            let roomID = req.parameters.get("roomID"),
            let playerRaw = req.parameters.get("playerID")
        else {
            ws.close(promise: nil)
            return
        }

        let room = req.application.roomManager.room(for: roomID)
        let playerID = PlayerID(playerRaw)

        // Join the room when connected
        Task {
            await room.handle(.join(playerID: playerID, name: playerRaw))
            let snapshot = await room.snapshot()
            try? await ws.send("joined:\(snapshot.players.count)")
        }

        ws.onText { _, text in
            Task {
                // Simple demo: if text is "hit:XXX:10", treat it as an attack command
                if text.hasPrefix("hit:") {
                    let parts = text.split(separator: ":")
                    if parts.count == 3,
                       let target = parts.dropFirst().first,
                       let damageStr = parts.last,
                       let dmg = Int(damageStr) {

                        let targetID = PlayerID(String(target))
                        await room.handle(.attack(
                            attacker: playerID,
                            target: targetID,
                            damage: dmg
                        ))

                        let snapshot = await room.snapshot()
                        if let targetState = snapshot.players[targetID] {
                            try? await ws.send("hp:\(targetID.rawValue):\(targetState.hp)")
                        }
                    }
                } else {
                    // Echo back the message
                    try? await ws.send("echo:\(text)")
                }
            }
        }

        ws.onClose.whenComplete { _ in
            Task {
                await room.handle(.leave(playerID: playerID))
            }
        }
    }
}

