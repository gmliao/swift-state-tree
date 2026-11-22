# Turn core: record timer wakes so mail replay reproduces their batches (#756)

**Status:** rev 2, design only, GO from Review (one should and two nits folded in below). Not implemented; #756 carries it (before release, with #612 and #745). Today's behavior and its documented limit are in PR #753 (`2026-11-21-turns-shared-deadline-timer.md`).

Rev 2 (Review of rev 1: shape (2) holds; 3 must-fix, 2 shoulds, 2 nits):
- §3.3 (MF 1): a marker runs from a non-reentrant pump at the start of each outside entry and in `finishReplay`, never from a check inside a segment. A check stops at a marker and leaves it staged. The pump is off during a replay wake.
- §2, §3.4 (MF 2): the take count t is replaced by an explicit selection key, the `before` position at which the live wake read its due list. Replay runs the wake's pre-selection phase with that key as a stop, and checks that it ends there. `takenFor` stays in replay.
- §3.5 (MF 3): each fired entry records the `now` its segment read, and replay serves it. One wake timestamp isn't enough.
- §3.6 (should 1): the record says why selection stopped (no live entry left at or before the target, the fire cap, the stale cap). Replay checks the end of the batch, not only its prefix. Reporting a divergence no longer moves the cursor.
- §5 (should 2): fixtures for a marker met at a trailing check, a trailing marker run by `finishReplay`, and an empty marker followed by another at the same ordinal. The replay side never waits for a wake.
- Nits: no byte estimate (the encoding is the adopter's); the status line cites #756.

## 1. The problem

The shared timer (#621 item 2, PR #753) fires each wake's due entries as one batch: it reads a due list from the heap, then fires each entry as its own entry. A mail replay (#738, `2026-11-21-turn-core-post-lane.md` §3.9) places each mail by the ordinal of the entry it stepped before, `before(k, i)`, and steps it at the first check where k is next. That check can be the trailing check of the previous segment, before the wake ran live.

So which entries a wake fires can depend on whether a mail stepped before the wake or inside it, and the record doesn't say which. #753 fixed the single case Review traced: the wake's first live entry takes the mail before the due list is read, so mail that arms one entry at or before the target groups the same way live and in replay. These still diverge, undetected:

- **chained arm:** mail M arms C@4, and C's step arms D@4;
- **the caps:** a wake stops at 64 live fires or 256 stale pops, and the next wake takes the rest; replay's grouping depends on where mail fell between them;
- **mail at more than one take:** the wake's take steps M1, and M2, which M1's `flush` posted, steps either in the take's own segment (budget left) or at a later fresh take (budget spent); replay coalesces both into one check.

Replay also has no sleeper of its own today: it fires a deadline when the replay's clock reaches it, and a fired entry reads the replay's clock, not the time the live wake ran.

## 2. The idea: give the wake a position in the record

The wake goes into the record at the place it ran, as the maintainer suggested: number things as they come in. The wake isn't an input and takes no ordinal itself (its fired entries do), so its position is a **marker** in the `before(k, i)` sequence.

Live, a wake that reaches a live head (a due entry that isn't stale) does this, in order:
1. **Marker.** It reserves `before(k, j)`, the next `before` key, before its take. Mail stepped before the wake (a trailing check, a mailbox wake) is keyed below it.
2. **Pre-selection phase.** The take for the first live head (`beginEntry`): `takeMailBeforeStep` steps mail under a fresh budget, and its products-first segment steps their products. That segment can dispatch steps (a send queued by a mail's `flush`), which take ordinals, and its loop checks can take more mail.
3. **Selection.** The due list is read from the heap that phase left. Its position is the **selection key** `before(ks, is)`: the next `before` key at that moment. Every mail of the pre-selection phase is keyed below it; mail taken later (the first fired entry's own take when it isn't the head the take was made for, later entries' takes) is keyed at or above it.
4. **Fires**, each as its own entry (#753's `fireDeadline`), the first one skipping its take when it is the head the take was made for (`takenFor`).

A wake that reaches no live head (all its due entries stale) changes no state and isn't recorded.

## 3. Design

### 3.1 Two shapes

**(1) The wake as an ordered event.** The marker records the target and the selection key. Replay runs the wake's own algorithm at the marker (the same loop, caps included) and derives the batch.

**(2) The marker plus its recorded batch.** The marker records the target, the selection key, the batch (each fired entry's ticket and `now`, in order) and why selection stopped. Replay builds its own list from its heap and checks it against the record.

| Case | (1) event | (2) marker + batch |
|---|---|---|
| C, A, B (M arms C@4) | marker; the pre-selection take steps M; the loop finds C, A, B | same; C, A, B checked |
| chained arm (C arms D@4) | D isn't due in this wake (armed after selection); the next marker fires it | same |
| 64 cap | each live wake is its own marker; the loop's cap gives the same split | each marker names its batch: 64, then the rest |
| 256 stale cap | a stale-only wake isn't recorded, so replay's heap holds its stale entries at the next wake, and the stale cap can stop that wake's list early: the batch differs. (1) would have to record stale-only wakes too | a stale-only wake isn't recorded; replay pops stale entries without the cap and takes the recorded batch, so stale entries don't decide it |
| M1, M2 across takes | the selection key says whether M2 stepped before selection | same |

**The no-state-change rule.** An entry that changes no state takes no ordinal (#738 round 4). Neither shape gives a marker an ordinal. (1) still has to record wakes that change no state; (2) records only wakes that reach a live head.

**Recommendation: (2).** It records only wakes that do something, its replay doesn't depend on how stale entries piled up, and a wrong batch is reported at the wake that went wrong, not later as a changed output.

### 3.2 The record

A marker is a `MailRecordEntry` keyed `before(k, j)` whose content is a wake (`MailRecordWake`):
- `target`: the instant the sleeper slept until;
- `selection`: the selection key `before(ks, is)`;
- `fires`: per selected entry, in order, its ticket (a request or follow-up id, or a timer key and generation, with its kind) and the `now` its entry's segment read (§3.5). A selected entry that is stale at its own `fireDeadline` re-check has no step, so its `now` is nil, as for a stale mail check;
- `stop`: why selection stopped: `exhausted` (no live entry left at or before `target`), `fireCap` (64 selected) or `staleCap` (256 stale entries popped).

A wake whose take staled every due entry is recorded with no fires and `stop: exhausted`. The live loop's 256 stale pops before the first live head stay unrecorded (no state).

### 3.3 Where a marker runs (MF 1)

A marker never runs from inside a segment: firing there would reach `beginEntry` → `takeMailBeforeStep`, which stops with "an entry's mailbox take inside a segment", and a nested `runSegment` returns at once.

- **A check stops at a marker.** `takeStaged` steps the staged mail for the current key and stops when the head is a marker, leaving it staged. This holds for every check: an entry's take and a segment's loop check alike.
- **The pump.** `runReplayWakes()` runs while the core is between entries (not in a segment, no borrow) and no replay wake is running. In a loop, it steps the staged mail keyed for the current position below the next marker (as an entry's take, with its own products-first segment), then, when the head is a marker for the current position, consumes it and runs the wake (§3.4). It ends when the head is neither.
- **When it runs.** First thing in every outside entry in replay, before the entry reads or changes any state: `send` and `sendAndWait` at submission, a query from outside, an effect's completion and a gate's return (before their pre-checks), a continuation job (before `continueBatch` captures the due follow-ups), and `finishReplay` (before it reports leftovers). Live, the wake ran before that entry arrived, so the entry sees the state after it.
- **Off during a replay wake.** The wake sets a flag that the pump checks, so a fired entry's segment epilogue or its take can't run a second marker before the batch ends. A second marker at the same position (an empty wake followed by another wake) runs on the pump's next iteration, after the first wake returns.
- **Reads.** `read` doesn't run the pump: it changes no state. A replay driver that reads between entries sees the state before a pending marker. Replay compares outputs, not reads. A reader that decides from `read` (#700's keeper: the initialization barrier, the frozen flag, the adapter's reads) could decide differently before a pending marker under #612's replay: such a reader runs the pump first, or the replay adopter (#612) owns that ordering.

A marker still staged when its ordinal is dispatched is reported `unconsumed` by `noteDispatch`'s existing check; one still staged after `finishReplay`'s pump is `leftover`.

### 3.4 Running a recorded wake (MF 2)

`replayWake(marker)`:
1. Consume the marker (`beforeIndex += 1`), set the wake flag and `sleeperAwake`.
2. **Pre-selection.** Find the first live head at or before `target`, as live does, and remember its order (`takenFor`). Run `beginEntry()` with the selection key as a stop: `takeStaged`, in the take and in its segment's loop checks, steps no staged entry at or above the stop. The products-first segment dispatches what it dispatches (the same state gives the same steps); the stop only holds back mail live took later.
3. **Check the selection point.** `(nextOrdinal, beforeIndex)` must equal the selection key; otherwise report the divergence (§3.6).
4. **Selection.** Pop stale heads without the stale cap; take live heads at or before `target` until the recorded number of fires. Check the tickets against the record, then the stop (§3.6).
5. **Fires.** Fire the recorded entries that are live, in recorded order, through `fireDeadline`. The first skips its take only when its order is `takenFor`, as live. Each fire serves its recorded `now` (§3.5).
6. Clear the flag and `sleeperAwake`.

Replay starts no sleeper: `armDeadline` pushes the entry and returns, and the replay's clock fires nothing. Markers alone fire. An entry armed in replay that no marker names stays in the heap; at the record's end it stays there, as a live core's pending entries do.

### 3.5 `Turn.now` of fired entries (MF 3)

Live, each fired entry runs `beginEntry`, which clears the cached `now`, so each one reads the clock when its step asks: a wake for instant 5 can run at 20, and two entries of one wake can read different times. Relative request and gate deadlines are computed from `segmentNow()`, so the time also changes the heap.

- **Live, with a recorder set:** each fire reads `segmentNow()` after its take, before its boundary, and the value goes into its `fires` element. Reading it eagerly per fire follows #738's per-check `now` (`MailRecordEntry.now`), which a check records whether or not its step reads the clock. For the first fire when it skipped its take, that is the `now` the pre-selection segment cached, as its step reads.
- **Replay:** after the fire's take, the recorded `now` becomes the entry's cached `now` (`cachedNow`), so the fire's step and its segment read it, and so do the deadlines they arm. The pre-selection segment's products read the served `now` of the staged mail before them, as #738 already does.
- **Behavior change, for the PR text:** a replayed fire's `Turn.now` is the recorded time of the live fire, not the replay's clock.
- **Cost:** one clock read per fire, only with a recorder set.

### 3.6 Mismatches and the cursor (should 1)

- **Ticket mismatch:** a recorded ticket missing, stale or out of order in replay's list.
- **End of the batch:** with `stop: exhausted`, the next live head after the recorded fires must be later than `target` or absent, so a dropped last ticket is detected, and so is an empty batch where replay has a due entry. With `fireCap` there must be such a head; with `staleCap` replay checks the prefix only, because live stopped for a reason replay doesn't have.
- **Selection point:** step 3 above.
- All three report a new case, `wakeMismatch(key)`, the marker's key. The recorded fires that are live then fire in recorded order, to keep the later keys aligned as far as they can be.
- **Reporting doesn't move the cursor.** Today `diverged` removes the staged head before reporting. It is split: the report names a key and removes nothing, and the callers that drop a head (`noteDispatch`'s unconsumed loop, `finishReplay`'s leftover loop) remove it themselves. A wake mismatch then doesn't skip the next record.
- **Not detected:** a marker deleted from the end of a record, with nothing staged after it. Its fires are missing, and only the replay's output comparison shows that. The corruption tests cover a dropped ticket, an added ticket, a dropped marker with a later entry, and a wrong selection key.

### 3.7 Format and compatibility

- `MailRecordEntry` (package) replaces `mail` with a content enum: `.mail([Mail])` or `.wake(MailRecordWake)`. `MailRecordKey` doesn't change; a marker and a selection key are `before` keys. The recorder hook `onMailTaken` receives entries.
- No version marker. No record exists outside SwiftStateTurns' tests: the keeper isn't on the turn core until #612. A record made before #756 has no markers, so its replay fires no deadline: mail keyed after the first fire is reported, and otherwise the outputs differ. No compatibility path is kept.
- Public API: none. The package delta is the content enum, `MailRecordWake`, its fire and stop types, `wakeMismatch`, and the hook's type. `@usableFromInline` where the inlinable paths (`takeStaged`, `timerWoke`) need them. No must-not-compile snippet: nothing public changes.
- The in-memory sizes aren't an encoding. The adopter's record encodes the entries.

### 3.8 #745

The same kind of fix: record the decision instead of deriving it (rr). #745 records each input's admission ordinal, so replay runs the continuation jobs due before it. A continuation job is also an event between entries, and could take a marker case of its own, run by the same pump. Whether #745 does is its decision. Until then the guarantee keeps #745's gap: a continuation job a wake's segment schedules can replay after the next input.

### 3.9 Cost

- Live, every core with a mailbox: one `before` index per wake that reaches a live head, and remembering the selection key.
- Live, with a recorder: the batch's tickets and one clock read per fire.
- Replay: behind `mailReplay != nil`; the pump's check at each outside entry is a nil test on a live core.
- No TurnsBench bench runs a wake (its clock never lets a deadline pass). A/B tier: none for TurnsBench; a Mac output check of TurnsMailboxBench if any of its benches wakes.

## 4. Review's rev 1 checklist, where answered

1. Record shape: §3.2. 2. Replay consumption: §3.3, §3.4, §3.6. 3. Coverage: §5. 4. The wake's own take: §2, §3.4. 5. #753's shoulds: `takenFor` stays live and in replay (§3.4 step 5); 13zc3–13zc5's live "remainder #1" check stays. 6. Format: §3.7. 7. #745: §3.8. 8. Cost: §3.9.

## 5. Tests (through `liveThenReplay`, with holds; each fails with its feature removed)

The replay side never waits for a wake event: markers run synchronously from the pump, so a replay closure only sends its inputs, and the harness calls `finishReplay()` after them.

- C, A, B: #753's 13zk3, with the marker and its batch checked in the record.
- Chained arm: M arms C@4, C's step arms D@4; both runs log M, C, A, B, D; D fires on a second marker.
- 64 cap: 65 timers due at once, plus mail held behind the first wake that arms one more at the target; the batches are 64 and the rest in both runs.
- 256 stale cap: 300 closed entries and one live entry due; the stale-only wakes aren't recorded; replay's one marker fires the live entry.
- M1, M2: the wake's take steps M1, whose `flush` posts M2. Two variants: budget left (M2 steps in the take's segment, below the selection key) and budget spent (M2 steps at the first fire's own take). Replay groups both as live.
- A pre-selection dispatch: M1's `flush` sends S, which dispatches before selection; the selection key's ordinal is past the marker's.
- `Turn.now`: a wake for 5 runs at 20 (the test clock holds the wake), two fires read different times (hold between them), and one arms a relative deadline; replay with a different clock gives the same log and the same deadline.
- Harness fixtures (should 2): a marker met at a trailing loop check (the next entry's pump runs it); a trailing marker run by `finishReplay`; an empty marker followed by another marker at the same ordinal.
- Divergences: a dropped ticket, an added ticket, a dropped last ticket under `exhausted`, an empty batch with a due entry, a wrong selection key, a dropped marker followed by a later entry. Each reports the expected key without skipping the next entry.
- Mutants: no stop at the marker; the pump running inside a segment; the pump on during a replay wake; no selection stop; `takenFor` ignored in replay; the recorded `now` not served; the end-of-batch check removed; `diverged` moving the cursor.

## 6. Steps (when #756 is scheduled)

1. The content enum, the marker and selection key, the recorded batch and `now` (live).
2. `diverged` split into reporting and cursor moves.
3. Replay: no sleeper, the stop in `takeStaged`, the pump at each outside entry and in `finishReplay`, `replayWake`.
4. #753's replay tests whose replay side waits for a physical wake (13t, 13x, 13zj, 13zk and their helpers) rely on the pump instead.
5. The tests and mutants above.
6. The docs' limit paragraph (#753) becomes the rule: a replay fires each wake at its recorded place with its recorded batch and times, with #745's gap still stated.
