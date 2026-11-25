---
title: "A Swift block in the Turns docs must appear in a tested file"
module: SwiftStateTurns
date: 2026-11-19
problem_type: gotcha
component: turns-documentation
symptoms:
  - "\"Every Swift block in the documentation appears in the tested files\" fails"
  - "a docs/turns or DocC edit passes pre-push-checks.sh and breaks main"
root_cause: docs_turns_swift_blocks_are_checked_by_a_swift_test_that_pre_push_doesnt_run
resolution_type: design_rule
severity: medium
tags:
  - documentation
  - turns
  - docc
  - testing
  - pre-push
related:
  - "f515e11f"
---

**Problem.** A section added to `docs/turns/README.md` and its `.zh-TW.md` mirror (f515e11f, pushed straight to `main`) had a before/after ```swift example. `SwiftStateTurnsTests` › "Every Swift block in the documentation appears in the tested files" then failed on `main`.

**Root cause.** That test (`Tests/SwiftStateTurnsTests/WorkedExampleTests.swift`, `documentationMatchesTheTests`) reads every ```swift block in the DocC catalog (`Sources/SwiftStateTurns/SwiftStateTurns.docc`) and in `docs/turns/README*.md`. Each block must appear, with leading spaces dropped, in `WorkedExampleTests.swift`, `ComparisonTests.swift` or `ConceptsTests.swift`. `docs/` isn't a core path, so the edit went to `main` without a PR. `scripts/pre-push-checks.sh` runs lints, not tests, so nothing ran the check before the push.

**Fix.** The example was split into one block per form, in both languages, and the four blocks were compiled in `ConceptsTests.swift`, each in its own namespace. The types its fields name sit at file scope, because `@PlainData` writes its extension there and names the field types unqualified.

**Prevention.** A ```swift block in `docs/turns/` or the Turns DocC catalog is test input. Before pushing such an edit, put the block's code in one of the three test files and run `swift test --filter SwiftStateTurnsTests`. Blocks in other languages and inline code aren't checked.
