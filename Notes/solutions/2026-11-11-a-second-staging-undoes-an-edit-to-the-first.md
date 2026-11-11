---
module: SwiftStateTreeTransport
date: 2026-11-11
problem_type: bug_class
component: sync-plan-staging
symptoms:
  - "a row dropped from a plan is bound anyway"
  - "Row entry on unbound slot"
  - "an edit to a staged write has no effect"
root_cause: two_stagings_of_one_write_in_one_plan
resolution_type: code_fix
severity: high
tags:
  - sync-tables
  - staging
  - row-addressing
  - remake
related:
  - "#487"
---

**Problem.** With row addressing, a row that fails to encode is dropped from the plan, and the plan is made again without it (`dropRow` on the staged rows). A row in the first join's seed was not dropped: the server bound its slot, the client never got the create, and the row's next column set threw "Row entry on unbound slot" on the client.

**Root cause.** One plan staged the tables' seed twice: once in the broadcast diff (`planDiff`, because the tables weren't seeded) and again in a joiner's view (`lateJoinSnapshot`, by the same test against the committed tables). The second staging replaced the staged rows keyed by field name, and the remake had dropped the row only from the first. The view was built from the second, and both commits ran, the second last. The first fix tried, making a seed's rows droppable, did nothing for that reason. A test that only checked the drop's return value would have passed.

**Fix.** `SyncTableBroadcastDiff.stageSeed` skips a field that this plan has already seeded (`SyncTableStaged.seededFields`). So one plan stages each field once, and an edit to that staging holds.

**Prevention.**
- A check such as "is it seeded?" that reads the committed state, made at two points of one plan, is true at both. When the act stages a write, the second one duplicates it. Make the staging idempotent per plan, keyed by what it writes, or check the plan's staged state too.
- When a later step edits a staged write (drop, trim, replace), test the committed result and what the client received, not the edit's return value.
- `RowAddressingAdapterTests.seedRowDrop` pins this case.
