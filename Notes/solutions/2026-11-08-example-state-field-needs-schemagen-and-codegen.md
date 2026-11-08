---
module: Examples
date: 2026-11-08
problem_type: gotcha
component: example-schema-codegen
symptoms:
  - "CI's `examples` job fails at \"Generated files are current\""
  - "schemaHash in Examples/GameDemo/schema.json differs after `swift run SchemaGen`"
  - "GameDemo tests and E2E pass locally, main's CI is red"
root_cause: synced_field_added_without_regenerating_checked_in_schema_and_codegen
resolution_type: design_rule
severity: medium
tags:
  - ci
  - schema
  - codegen
  - examples
  - verification
related:
  - "da57676a"
  - "217df22a"
---

# A synced field added to an example land needs SchemaGen and codegen in the same commit

## Problem

da57676a added two synced fields (`joins`, `leaves`) to `ResolverTestState`. The checked-in `Examples/GameDemo/schema.json` and `WebClient/src/generated/{defs.ts,schema.ts,resolver-test/testHelpers.ts}` weren't regenerated, so main's `examples` job failed at "Generated files are current" from that push on. That also blocked the open PRs that merge main. 217df22a regenerated them.

## Root cause

The schema and the client codegen are derived from the land's state types, but they are checked in. Nothing in the local verification for an example change (GameDemo `swift test`, `test-e2e-game.sh`) regenerates them: the E2E servers serve their schema live, and the tests don't compare it with the checked-in copy. Only CI's `examples` job regenerates both examples' schemas and WebClient codegen and fails on any difference. The direct pushes were reported done before main's CI finished.

## Fix

Run what CI runs, from a clean tree (in a fresh checkout, `npm ci --prefix sdk/ts` first, or codegen picks up a global `tsc`):

```bash
(cd Examples/Demo && swift run SchemaGen --output schema.json)
(cd Examples/GameDemo && swift run SchemaGen --output schema.json)
npm ci --prefix sdk/ts
npm run codegen --prefix Examples/Demo/WebClient
npm run codegen --prefix Examples/GameDemo/WebClient
git status --porcelain   # must list only the generated files
```

## Prevention

- Any change to a synced field of an example land (added, removed, renamed, its type or sync policy) regenerates the schema and the codegen in the same commit.
- After every direct push to main, watch main's CI to green before reporting the change done. Local tests and E2E don't run this check.
