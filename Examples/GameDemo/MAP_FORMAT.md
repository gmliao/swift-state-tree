# Map Format Specification

This document describes the JSON map format used by the Hero Defense game, designed to be compatible with Tiled Map Editor.

## Overview

The map format is based on Tiled's JSON format but simplified for our tower defense game. It supports:
- World boundaries
- Base/fortress position
- Turret placement slots
- Spawn points for monsters
- Visual representation with colored tiles

## JSON Structure

```json
{
  "version": "1.0",
  "width": 128,
  "height": 72,
  "tilewidth": 1,
  "tileheight": 1,
  "base": {
    "x": 64,
    "y": 36,
    "radius": 3
  },
  "turretSlots": [
    {
      "id": "slot1",
      "x": 72,
      "y": 36
    },
    {
      "id": "slot2",
      "x": 56,
      "y": 36
    },
    {
      "id": "slot3",
      "x": 64,
      "y": 44
    },
    {
      "id": "slot4",
      "x": 64,
      "y": 28
    }
  ],
  "spawnPoints": [
    {
      "id": "spawn1",
      "x": 0,
      "y": 0,
      "edge": "top"
    },
    {
      "id": "spawn2",
      "x": 128,
      "y": 36,
      "edge": "right"
    },
    {
      "id": "spawn3",
      "x": 64,
      "y": 72,
      "edge": "bottom"
    },
    {
      "id": "spawn4",
      "x": 0,
      "y": 36,
      "edge": "left"
    }
  ],
  "layers": [
    {
      "name": "background",
      "type": "tilelayer",
      "width": 128,
      "height": 72,
      "data": []
    }
  ]
}
```

## Field Descriptions

### Top Level
- `version`: Format version (currently "1.0")
- `width`: World width in game units (Float)
- `height`: World height in game units (Float)
- `tilewidth`: Width of each tile in game units (default: 1.0)
- `tileheight`: Height of each tile in game units (default: 1.0)

### Base
- `base.x`: X coordinate of base center
- `base.y`: Y coordinate of base center
- `base.radius`: Base radius in game units

### Turret Slots
Array of predefined positions where turrets can be placed:
- `id`: Unique identifier for the slot
- `x`: X coordinate
- `y`: Y coordinate

### Spawn Points
Array of monster spawn positions:
- `id`: Unique identifier
- `x`: X coordinate
- `y`: Y coordinate
- `edge`: Which edge of the map ("top", "right", "bottom", "left")

### Layers (Tiled Compatible)
For visual representation, compatible with Tiled:
- `name`: Layer name
- `type`: Layer type ("tilelayer", "objectgroup", etc.)
- `width`: Layer width in tiles
- `height`: Layer height in tiles
- `data`: Tile data array (optional, for visual tiles)

## Tiled Compatibility

This format is designed to work with Tiled Map Editor:
1. Export your map as JSON from Tiled
2. Extract relevant data (base, turret slots, spawn points)
3. Add game-specific metadata
4. Use in game for initialization

## Example Map

See `map.json` for a complete example map file.
