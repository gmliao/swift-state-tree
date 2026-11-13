# A player's second session gets no per-player changes (#531): findings

**Status:** findings for review. No code. Read at `main` 9755a625. Each fact is marked **checked** (read in the code) or **inferred** (reasoned, to be pinned by a test in the fix).

**Summary.** #531's mechanism holds. Two adapter members of one player share one per-player baseline, so only the first recipient in the sync loop gets that player's per-player changes. The issue's reachability holds too: only the public `TransportAdapter.registerSession(...)` creates the second member.

Two findings sharpen the issue:
- **The order is hash order, not join order.** "The first session" is whichever comes first in a `Dictionary`'s iteration, which varies per process.
- **The keeper allows one entry per player.** A second keeper join kicks the first, and inputs from any session but the last are rejected. So a supported second session would need keeper changes too, not only a per-session sync baseline.

The recommended fix is that `registerSession` supersedes, as the library's own joins do (option A).

## 1. The reproduction path

1. **Join** a player through any library join (`performJoin`). Admission supersedes other sessions and registers the member in one synchronous segment (`admitJoining`, `TransportAdapter.swift:1773-`; `supersedeSessions`, :1956-1990). Checked.
2. **Register a second session** for the same player with the public `registerSession(sessionID:clientID:playerID:authInfo:connectionGeneration:)` (`TransportAdapter+Membership.swift:13-33`). It calls `_registerSessionImpl` (`TransportAdapter.swift:1632-1663`), which adds the member without admission. Its DocC says so: "the player's other sessions stay members". Checked.
3. **Seed it**, as the tests do with `syncStateForNewPlayer(playerID:sessionID:)` (`TransportAdapterSyncLagTests.swift:366-367`, :488-489).
4. **Change a per-player field** and run a normal sync. Both sessions are recipients (`syncPhaseRecipients`, :4199-4209, every joined member). Each recipient diffs against `staged.perPlayer[playerID] ?? lastPerPlayerSnapshots[playerID]` and stages its new snapshot under the same `playerID` (`collectPerPlayerOnlyPendingUpdates`, :5133-5172; `collectCombinedPendingUpdates`, :5174-5212). So:
   - the first recipient gets the changes;
   - the second diffs against what the first staged and gets `.noChange`, which is skipped (:5157-5159). In the combined frame it gets the broadcast part only. Checked.

**Which session is "first"** (checked): recipients come from `MembershipCoordinator.allJoinedEntries()`, which maps over the `sessionToPlayer` dictionary (`MembershipCoordinator.swift:237-239`). The order is the dictionary's, which depends on the per-process hash seed. So which of the two sessions gets the changes can differ between runs and processes, unless `SWIFT_DETERMINISTIC_HASHING` is set.

**In the library:** `registerSession`'s only library caller is `performJoin` (:2320), right after admission, so it never makes a second member. Hosts and tests are the remaining callers: `TransportAdapterSyncLagTests` (:366, :488, deliberately two members), and the test helper (`TransportTestHelpers.swift:51`) with a fresh player each time (inferred from its use; checked per call site in the fix).

## 2. Code that assumes one session per player

**Keyed by player in the sync path (each one breaks with two members):**

| State | Where (checked) | With two members |
|---|---|---|
| Per-player baseline `lastPerPlayerSnapshots: [PlayerID: StateSnapshot]` | `SyncEngine.swift:66`; written by `applyStaged` (:94-102) | one baseline for two views: the #531 bug |
| Staged per-player caches `StagedCaches.perPlayer` | `SyncEngine.swift:85-91` | the second recipient diffs against the first's staged snapshot |
| `hasReceivedFirstSync: Set<PlayerID>` | `SyncEngine.swift:85-108` | a second session's first diff isn't a `firstSync`, since the player already had one (inferred from the set's key) |
| `initialSyncingPlayers[playerID]` | `TransportAdapter.swift:1756-1761`; skipped in `syncPhaseRecipients` (:4203) | while one session seeds, **every** session of the player is left out of the sync phase |
| A seed's cache write | `syncStateForNewPlayer` (inferred: the seed commits the player's per-player snapshot) | the second session's seed moves the first session's baseline, so the first misses the changes between its last frame and that seed (inferred; to be pinned) |
| Cache clear `clearCacheForDisconnectedPlayer(playerID)` | `SyncEngine.swift:1186-1189`; called at supersede (:1984) and at the player's last disconnect (:1604) | per player; the disconnect path already guards it by "no other session" (:1595-1610) |

**Keyed by player outside the sync path:**
- **The keeper holds one entry per player** (`players: [PlayerID: InternalPlayerSession]`, `LandKeeper.swift:280`). Checked.
  - **A duplicate join kicks the old entry** ("Kick Old strategy"): `leave` with the old client and session, so OnLeave runs (:1619-1625). The new entry is then `isFirst`, so OnJoin runs again (:1628-1633). The game sees a leave and a join; the adapter keeps both members.
  - **Inputs:** `rejectSenderIfSuperseded` rejects any sender whose client or session isn't the entry's last (:1844-1864, #92). With two members, only the last-joined session can send. The other still receives sync, and it may be the one that gets the per-player changes (hash order, §1).
  - **Leave:** `leave` returns early when the session isn't the entry's last (:2366-2371), so the older session's disconnect doesn't end the player. The newer session's does, while the older stays a member without a keeper entry.
- **Disconnect** invalidates the player's membership version, which drops the player's queued `.player` events "for every session of the player, a remaining one included" (`TransportAdapter.swift:1569-1578`). Checked.

**Code that already handles several sessions** (checked):
- `classifySyncLag` gives every session of a resyncing player the resync view (:3365-3410). Since the baseline is per player, a resync for one moves it for all.
- `.player` targets expand to all the player's sessions (`sessionIDs(for: .player(…))`, :2985).
- The disconnect path keeps the player's state while another session remains (:1595-1610).

These are the "supported in parts" #531 mentions. They don't make two members correct, since the keeper and the baseline are per player.

## 3. Fix options

| | What | Public API impact | Other impact |
|---|---|---|---|
| **A. Supersede in `registerSession`** (newest wins, as `performJoin`) | `_registerSessionImpl` calls `supersedeSessions(of:keeping:)` in the same synchronous segment as the member insert, as `admitJoining` does | no signature change. The DocC's "the player's other sessions stay members" becomes "newest wins, as a join". Behavior change: a host's older session is closed (superseded) instead of kept | matches the keeper's kick-old and #92. `TransportAdapterSyncLagTests`' two-member cases (:366, :488) become supersede cases. The multi-session branches of `classifySyncLag` and the disconnect path become unreachable from the public API; they are kept, or removed with a test that shows they can't be reached. #514's frame-identity case pinned for #531 changes deliberately |
| **B. Refuse a second registration** | `registerSession` refuses when the player already has a member | a source break: `async` becomes `async throws` (callers add `try`), or a `@discardableResult` `Bool`/outcome return that callers can ignore silently. A new error case (e.g. `playerAlreadyHasSession`) | the host chooses what happens to the older session. The library's own `performJoin` call must not trip it (admission already superseded, so it doesn't; checked by a test). Silently ignorable if the return form is chosen |
| **C. Support several sessions per player** | a per-session baseline: `lastPerPlayerSnapshots`, the staged per-player caches, `hasReceivedFirstSync` and the initial-sync marker keyed by session, not player. Or diff once per player and fan out, correct only when the sessions share a baseline | additive in the adapter, but the keeper's one-entry model (kick-old, `rejectSenderIfSuperseded`, `leave`'s session check) must change too, or the extra sessions stay receive-only. That is a public behavior change of joins (#92's newest wins) | per-player sync memory and diff work × sessions. #514's per-player tables are keyed by player and would be keyed by session. The largest change; no repository use needs it |

**Recommendation: A.** The library already has one session per player, end to end: admission, the keeper's entry, and the sender check. `registerSession` is the only path that breaks it, and it is documented as "for a session whose keeper join the caller already did", which the keeper has superseded anyway. A brings that path in line with no signature change. B is a weaker form of A that pushes the choice to the host at the cost of a source break or an ignorable result. C is a feature (multi-device for one player) and should be its own issue if wanted.

## 4. Tests for the fix (option A)

- **Red first:** two members via `registerSession`, a per-player change, a normal sync. Today one session gets the patch and the other gets nothing or the broadcast part only, and which one depends on hash order (pinned with deterministic hashing).
- **After A:** the older session is superseded (closed, its membership and ticket ended) in the same segment. The newer one gets the changes; no sync phase has two recipients for one player.
- **The library path:** `performJoin` → admission → `registerSession` supersedes nothing (admission already did), counted by `supersededSessionCount`.
- **Reentrancy:** a hold at `registerSession`'s `await webSocketTransport.registerSession(…)` (:1657) shows no sync phase sees two members of one player across it. The supersede and the insert run before that await (`HoldPoints`, not timing).
- **The rewritten sync-lag cases** cover the resync view's fan-out through a path that still exists, or are removed with the branch.
- **#514's pinned case** flips deliberately, as its plan says.

## 5. Open questions for review

- **Q1:** A, B or C. The recommendation is A.
- **Q2 (under A):** the multi-session branches in `classifySyncLag` and the disconnect path. Keep them (defensive, harmless), or remove them with a test that two members can't exist? The recommendation is to keep them, with an assertion in `syncPhaseRecipients` that no player appears twice.
- **Q3:** whether `registerSession` stays public at all. Its only library caller is `performJoin`. Making it `package` is a larger source break than B, and removes the host path #531 found.

## Related

#92 (newest wins), #514 (per-player sync tables; pins this output), #531.
