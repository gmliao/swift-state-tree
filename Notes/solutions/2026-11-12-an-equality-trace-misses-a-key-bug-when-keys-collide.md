---
module: SwiftStateTreeTransport
date: 2026-11-12
problem_type: testing_practice
component: change-object-metric
symptoms:
  - "a mutant that derives a different key survives a test that compares counts between two implementations"
  - "a differential trace of (changed, total) matches although one side keys a patch wrongly"
root_cause: a_count_comparison_hides_a_wrong_key_when_keys_collide_or_the_write_is_a_no_op
resolution_type: established_pattern
severity: medium
tags:
  - testing
  - mutants
  - differential
  - change-metrics
  - sync-tables
related:
  - "Notes/plans/2026-11-12-change-count-from-rows.md"
  - "Notes/solutions/2026-11-10-a-diff-replacement-must-match-the-old-diffs-quirks.md"
---

**Problem.** The change-object metric on the sync tables now counts each root dictionary of nodes from its entry count instead of from a snapshot. The test runs one script twice, metric from rows and the full-snapshot oracle, and compares changed objects, total, EMA and mode after every sync. A mutant that keeps the empty segments when splitting a patch path (so row `""`'s `/units//hp` keys `/units/` plus `hp` differently) survived. It survived a second time after the first fix.

**Root cause.** The test compares counts, not keys, so a wrong key only shows when it changes how many distinct keys there are. Two things hid it:
- The script wrote the empty key's row with `n = 0`, which was also the field's default, so the write made no patch.
- After that was fixed, the sync that changed row `""` also changed a row named `hp`. Today's rule keys `/units//hp`, `/units//pos` and `/units/hp/hp` as `/units/hp`, `/units/pos` and `/units/hp`: two keys. The mutant keys them `/units/`, `/units/` and `/units/hp`: also two. Different keys, the same count.

**Fix.** The script writes a value different from the default, and adds a sync where only row `""` changes, two nested fields. Today's rule gives two keys (`/units/hp`, `/units/pos`), the mutant one. The mutant now fails the trace. Landed with the change (see the plan).

**Prevention.**
- When a test compares an aggregate (a count, a hash of a set) between two implementations, check each mutant kills it, and for each key-derivation case give it a sync where that case alone decides the aggregate: no other change in the sync whose key could collide with it.
- A write in a test script must change the value. A write equal to the current value is no patch at all, and the case it was meant to cover is never reached.
