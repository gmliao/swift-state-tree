# Turn core: record timer wakes so mail replay reproduces their batches (#756)

**Status:** rev 1, design only, for Review's plan check. Today's behavior and its documented limit are in PR #753 (`2026-11-21-turns-shared-deadline-timer.md`). Not implemented; #756 carries it (before release, with #612 and #745). Decided by the maintainer on #73: option a, record the wake in the mail record.

## 1. The problem

The shared timer (#621 item 2, PR #753, `2026-11-21-turns-shared-deadline-timer.md`) fires each wake's due entries as one batch: it reads a due list from the heap, then fires each entry as its own entry. A mail replay (#738, `2026-11-21-turn-core-post-lane.md` §3.9) places each mail by the ordinal of the entry it stepped before, `before(k, i)`, and steps it at the first check where k is next. That check can be the trailing check of the previous segment, before the wake ran live.

So which entries a wake fires can depend on whether a mail stepped before the wake or inside it, and the record doesn't say which. #753 fixed the single case Review traced: the wake's first live entry takes the mail before the due list is read, so mail that arms one entry at or before the target groups the same way live and in replay. These still diverge, undetected:

- **chained arm:** mail M arms C@4, and C's step arms D@4;
- **the caps:** a wake stops at 64 live fires or 256 stale pops, and the next wake takes the rest; replay's grouping depends on where mail fell between them;
- **mail at more than one take:** the wake's take steps M1, and a later take in the same wake (an entry's own take, or the next entry X's) steps M2; replay coalesces both into one check.

## 2. The idea: give the wake a position in the record

Both shapes below put the wake in the record at the place it ran, as the maintainer suggested: number things as they come in. The wake isn't an input and takes no ordinal itself (its fired entries do), so its position is a **marker** in the `before(k, i)` sequence: `before(k, j)`, where k is the next ordinal and j the next `before` index when the wake reached its first live head.

- Mail stepped before the wake (a trailing check, a mailbox wake) is `before(k, <j)`.
- The wake's own take is `before(k, j+1 … j+t)`: after the marker.
- The first fired entry's boundary then takes ordinal k.

Replay treats a marker as a stop: a check steps staged mail up to it and no further, so the previous segment's trailing check can't step the wake's mail. The marker runs at the next point between entries, its take steps exactly t staged entries, and its fires follow.

## 3. Two shapes

**(1) The wake as an ordered event.** The marker records the target and t. Replay runs the wake's own algorithm at the marker (the same due loop, caps included) and derives the batch.

**(2) The marker plus its recorded batch.** The marker records the target, t, and the due list: the tickets the wake took into its batch, in order. Replay builds its own list from its heap (the first N live entries at or before the target, N the recorded count, stale entries popped without the 256 cap) and compares it with the recorded list.

How each comes out:

| Case | (1) event | (2) marker + batch |
|---|---|---|
| C, A, B (M arms C@4) | marker, take steps M, the loop finds C, A, B | same; C, A, B checked against the record |
| chained arm (C arms D@4) | D isn't due in this wake (armed during it); the next marker fires it | same |
| 64 cap | each live wake is its own marker; the loop's cap gives the same split | each marker names its batch; N = 64, then the rest |
| 256 stale cap | the stale-only wake changes no state, but if it isn't recorded, replay's heap holds its stale entries at the next wake, and the stale cap can stop that wake's list early: the batch differs. So (1) must record stale-only wakes too, as markers that take no mail | a stale-only wake isn't recorded; replay pops stale entries without the cap and stops at N, so the batch doesn't depend on stale entries |
| mail at more than one take | t splits the wake's take from the next take; without t, replay coalesces them | same (t is in both shapes) |

**The no-state-change rule.** An entry that changes no state takes no ordinal (#738 round 4). Neither shape gives a marker an ordinal. (1) still has to record wakes that change no state (stale-only), to keep the stale cap in step; (2) records only wakes that reach a live head.

**Recommendation: (2).** It records only wakes that do something, its replay doesn't depend on how stale entries piled up, and a wrong batch is reported at the wake that went wrong, not later as a changed output. Its cost over (1) is the ticket list, 9 bytes per fired entry.

## 4. Review's checklist

1. **Record shape.** A marker is a `MailRecordEntry` whose content is a wake: the target, t (the wake's take, as a count of `before` indices after the marker), and the batch's tickets in order (each a request or follow-up id, or a timer generation, with its kind). Position: `before(k, j)` as in §2. A stale-only wake (it reached no live head) isn't recorded. A wake that reached a live head is recorded even when its take found nothing (t = 0) or its batch is empty (the take staled every due entry).
2. **Replay consumption.** A replay core starts no sleeper: `armDeadline` pushes the entry and stops, so the replay's clock never fires a wake. Markers alone run wakes. An entry the replay armed that no marker names stays in the heap; a later marker may name it, and at the record's end it is left, as live leaves pending entries. Mismatches are reported, never absorbed:
   - a recorded ticket missing from the replay's list, an extra entry in it, or a different order: `.unconsumed(markerKey)` at the wake; the recorded batch's entries that are live then fire in recorded order, so the later keys stay as aligned as they can;
   - a marker still staged at the next dispatch: `.unconsumed`, from `noteDispatch`'s existing check;
   - a marker still staged after `finishReplay()`: `.leftover`.
3. **Coverage** (each through `liveThenReplay`, with holds, and each failing with the marker removed):
   - C, A, B: #753's 13zk3, now with its record checked for the marker;
   - chained arm: M arms C@4, C's step arms D@4; live and replay log M, C, A, B, D, and D fires on a second marker;
   - 64 cap: 65 timers due at once, mail held behind the first wake that arms one more at the target; the two markers' batches are 64 and the rest, in both runs;
   - mail at more than one take: M1 at the wake's take stales A; its flush posts M2, which the next entry's own take steps and which arms C@4; X sent after the wake; replay steps M1 at the marker and M2 at that entry, not both at one check;
   - 256 stale cap: 300 closed entries and one live entry due; the stale-only wake isn't recorded, and the replay's one marker fires the live entry;
   - the divergences: a record edited to drop a ticket, add one, or drop a marker reports `.unconsumed` or `.leftover`.
4. **The wake's own take.** It stays at the first live head, live as in #753. Its mail is keyed after the marker (§2), and replay steps exactly t staged entries there: a stop index that `takeStaged` honours, inside the take's segment too. So that mail steps at the wake, not at the previous segment's trailing check.
5. **#753's shoulds.** `takenFor` stays (live). In replay the first fired entry always makes its own `beginEntry()`: the take already stepped the marker's t entries, and anything keyed after them steps there, as it did live. 13zc3–13zc5's live "remainder #1" check stays.
6. **Format and compatibility.** `MailRecordEntry` (package) replaces `mail` with a content enum: `.mail([Mail])` or `.wake(MailRecordWake)`. `MailRecordKey` doesn't change: a marker is a `before` key. The recorder hook `onMailTaken` becomes one that receives an entry (or gains a sibling for wakes). No version marker: no record exists outside SwiftStateTurns' tests, because the keeper isn't on the turn core until #612. A record made before #756 has no markers, so its replay fires no deadline: mail keyed after the first fire is reported unconsumed or leftover, and otherwise the outputs differ. Such a record is refused only in that sense; no compatibility path is kept. Public API: none; the package delta is the content enum, `MailRecordWake`, and the hook. No must-not-compile snippet: nothing public changes.
7. **#745.** The same kind of fix: record the decision instead of deriving it (rr). #745 records each input's admission ordinal so replay runs the continuation jobs due before it. A continuation job is also an event between entries, so a marker of its own (`.continuation`) in the same sequence would serve. #756 builds the marker as a content case so #745 can add one; whether #745 uses it is #745's decision.
8. **Cost.** Live: one `before` index per wake that reaches a live head; the batch's tickets are copied only when a recorder is set. Replay code runs behind `mailReplay != nil`. No TurnsBench bench runs a wake (its clock never lets a deadline pass), and an unrecorded core records nothing. A/B tier: none for TurnsBench; a Mac output check of TurnsMailboxBench if any of its benches wakes.

## 5. Steps (when #756 is scheduled)

1. The content enum, the marker's reservation at the wake's first live head, the recorder hook (live).
2. Replay: no sleeper, the marker stop in `takeStaged`, the between-entries run (outermost `runSegment` epilogue, `takeMailBeforeStep`'s loop, `finishReplay`), the batch check.
3. #753's replay tests whose replay side waits for a physical wake (13t, 13x, 13zj, 13zk and their helpers) wait for the marker's run instead.
4. The coverage tests above; mutants: no stop at the marker, t ignored, batch not checked, a sleeper started in replay.
5. The docs' limit paragraph (#753) is replaced by the rule: a replay fires each wake at its recorded place with its recorded batch.
