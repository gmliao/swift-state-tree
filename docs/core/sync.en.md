[English](sync.en.md) | [中文版](sync.md)

# Sync and Sync Strategies

StateTree synchronization relies on `@Sync` + `SyncPolicy`, with SyncEngine generating snapshots/diffs.

## Design Notes

- Sync rules can be declared on types (`@Sync`), decoupled from handler logic
- Support per-player filtering to avoid unnecessary data leakage or bandwidth waste
- Use snapshot/diff merge mode to reduce sync costs

## SyncPolicy Types

- `.serverOnly`: Not synced to client
- `.broadcast`: All clients receive same data
- `.perPlayerSlice()`: Dictionary-specific convenience method, automatically slices `[PlayerID: Element]` to sync only that player's slice (**high frequency use**, no filter needed)
- `.perPlayer((Value, PlayerID) -> Value?)`: Requires manual filter function, filter by player (applicable to any type, **low frequency use**, for scenarios requiring custom filter logic)
- `.masked((Value) -> Value)`: Same-type masking (all players see same masked value)
- `.custom((PlayerID, Value) -> Value?)`: Fully custom

## Snapshot and Diff

- snapshot: Complete state (including per-player filtering)
- diff: Only send changes (path-based patches)

SyncEngine maintains:

- broadcast cache: Shared by all players
- per-player cache: Independent for each player

## First Sync

`StateUpdate.firstSync` is sent once after player cache is first established,
avoiding race conditions between join snapshot and first diff.

## Dirty Tracking

`@Sync` marks dirty on write, used to reduce diff costs.
TransportAdapter can switch dirty tracking at runtime:

- Enabled: Only serialize dirty fields
- Disabled: Full snapshot on every sync

## Manual Sync

In handlers, you can actively trigger sync through `ctx.syncNow()`.
