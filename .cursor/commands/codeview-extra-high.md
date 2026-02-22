# codeview-extra-high

Use Codex CLI to run a high-rigor code review on the current branch with **extra high reasoning effort** (`xhigh`).

## Goal

- Review only branch diff (against base branch)
- Prioritize: bugs, regressions, race conditions, missing tests
- Output actionable findings with file/line references

## Quick Run (Current Branch)

```bash
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
BASE="${1:-origin/main}"

codex review \
  --base "$BASE" \
  -c 'model="gpt-5.3-codex"' \
  -c 'model_reasoning_effort="xhigh"'
```

## Optional: Save Review to File

```bash
mkdir -p Notes/reviews
TS="$(date +%Y%m%d-%H%M%S)"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
BASE="${1:-origin/main}"

codex review \
  --base "$BASE" \
  -c 'model="gpt-5.3-codex"' \
  -c 'model_reasoning_effort="xhigh"' \
  | tee "Notes/reviews/${TS}-${BRANCH}-codeview.md"
```

## Need Custom Review Prompt? (Fallback)

`codex review --base` currently rejects positional prompts. Use `codex exec` instead:

```bash
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
BASE="${1:-origin/main}"

codex exec \
  -c 'model="gpt-5.3-codex"' \
  -c 'model_reasoning_effort="xhigh"' \
  "Review branch ${BRANCH} against ${BASE}. Run git diff against ${BASE}, then report findings by severity with file/line references, focused on correctness, regression risk, lifecycle/concurrency bugs, and missing tests."
```

## Notes

- `xhigh` is the Codex CLI value for extra high reasoning effort.
- Change `BASE` to `origin/feat/...` when reviewing stacked branches.
- If the repo has known flaky e2e tests, explicitly ask reviewer to separate product bugs from test-infra flakiness.

## Superpowers Skills

When acting on review findings, use **receiving-code-review** skill: verify before implementing, clarify unclear items, and push back with technical reasoning when feedback seems incorrect. For an alternative review flow (subagent), see **requesting-code-review**.
