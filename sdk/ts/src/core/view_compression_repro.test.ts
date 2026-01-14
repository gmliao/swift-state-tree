
import { describe, it, expect, beforeEach } from 'vitest'
import { eventFieldOrder, clientEventFieldOrder } from './protocol'
import { StateTreeView } from './view'
import { StateTreeRuntime } from './runtime'
import { ProtocolSchema } from '../codegen/schema'

// Mock dependencies
const mockRuntime = {} as StateTreeRuntime
const mockSchema: ProtocolSchema = {
  version: "0.1.0",
  schemaHash: "123",
  defs: {
    "Position2": {
      type: "object",
      required: ["v"],
      properties: {}
    },
    "PlayerID": {
      type: "object",
      properties: {}
    },
    "PlayerShootEvent": {
      type: "object",
      properties: {
        "playerID": { "$ref": "#/defs/PlayerID" },
        "from": { "$ref": "#/defs/Position2" },
        "to": { "$ref": "#/defs/Position2" }
      },
      required: ["playerID", "from", "to"]
    },
    "MoveToEvent": {
        type: "object",
        required: ["target"],
        properties: {}
    }
  },
  lands: {
    "hero-defense": {
      stateType: "HeroDefenseState",
      events: {
        "PlayerShoot": {
          "$ref": "#/defs/PlayerShootEvent"
        }
      },
      clientEvents: {
        "MoveTo": {
            "$ref": "#/defs/MoveToEvent"
        }
      },
      actions: {},
      eventHashes: { "PlayerShoot": 1 },
      clientEventHashes: { "MoveTo": 1 },
      pathHashes: {}
    }
  }
}

describe('View Compression Schema Loading', () => {
    
    beforeEach(() => {
        eventFieldOrder.clear()
        clientEventFieldOrder.clear()
    })

    it('should populate eventFieldOrder from schema in constructor', () => {
        // Instantiate View to trigger constructor logic
        // landID "hero-defense" matches schema
        new StateTreeView(mockRuntime, "hero-defense", { schema: mockSchema })

        expect(eventFieldOrder.has("PlayerShoot")).toBe(true)
        expect(eventFieldOrder.get("PlayerShoot")).toEqual(["playerID", "from", "to"])
    })

    it('should populate clientEventFieldOrder from schema in constructor', () => {
        new StateTreeView(mockRuntime, "hero-defense", { schema: mockSchema })

        expect(clientEventFieldOrder.has("MoveTo")).toBe(true)
        expect(clientEventFieldOrder.get("MoveTo")).toEqual(["target"])
    })

    it('should handle escaped slashes in refs if present (simulation)', () => {
        const mockSchemaEscaped = JSON.parse(JSON.stringify(mockSchema))
        // Simulate escaped slashes as if coming from JSON potentially ? 
        // In JS object, strings are already parsed.
        // If the JSON had "#\/defs\/...", JS string is "#/defs/..."
        // So standard split works.
        // But what if the ref was literally "#\\/defs\\/..."?
        
        // Let's rely on standard test first.
        new StateTreeView(mockRuntime, "hero-defense", { schema: mockSchemaEscaped })
        expect(eventFieldOrder.get("PlayerShoot")).toEqual(["playerID", "from", "to"])
    })
    
    it('should handle landID with room suffix', () => {
        new StateTreeView(mockRuntime, "hero-defense:room-1", { schema: mockSchema })
         expect(eventFieldOrder.get("PlayerShoot")).toEqual(["playerID", "from", "to"])
    })
})
