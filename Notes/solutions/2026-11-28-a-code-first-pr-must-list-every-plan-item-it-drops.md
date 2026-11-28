---
title: "A code-first PR must list every plan item it drops as a known gap, or the reviewer reads the plan's coverage as done"
module: process
date: 2026-11-28
problem_type: testing_practice
component: review-flow
symptoms:
  - "a PR body's table maps a must-fix to its tests, but one bullet of that must-fix has no code"
  - "a plan step that only bites once a later commit wires the code in (a callback that becomes a re-entry) is missing, and nothing says so"
root_cause: a_code_first_body_was_written_from_what_was_built_not_from_the_plan_items
resolution_type: process_fix
severity: medium
tags:
  - review
  - plans
  - code-first
  - known-gaps
related:
  - "#700"
  - "#990"
---

**Problem.** K2-2 commit 3 went code-first after two plan revisions (#990). Its body mapped each of the plan's must-fixes to a test. One must-fix had two bullets, and the second one was the in-step admission port: the adapter's supersede records a clear through the keeper, which the core counts as a re-entry once it is the adapter's keeper. That bullet had no code. The body still marked the whole must-fix as pinned and didn't list the bullet as a gap. Two smaller items were dropped the same way: the sender-side refusal and the facade's contract for the new server input. Review found all three by reading the plan against the diff.

**Root cause.** The body was written from what had been built, so it listed tests per commit. Nobody walked the plan's items one by one and asked where each went. A plan item that only matters once a later commit wires the code in is the easiest to drop: no test at this head fails without it.

**Fix.** The body's known gaps now name each dropped item, the commit that needs it, and the case that will pin it. The must-fix row says which bullet it covers.

**Prevention.** Before opening a code-first PR, go through the plan item by item, every bullet of every must-fix included. Give each item a status: done (with its test), moved to a named later commit (with the case that will pin it), or dropped (with the reason). Write the body's known gaps from that list, not from memory of the diff. A row that marks a must-fix as pinned must cover all of its bullets, or say which ones it covers.
