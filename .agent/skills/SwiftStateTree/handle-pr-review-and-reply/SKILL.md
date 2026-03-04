---
name: handle-pr-review-and-reply
description: Use when user wants to review PR comments on the current branch's PR, implement fixes, and reply under each specified comment thread on GitHub
---

# Handle PR Review Comments and Reply

## Overview

Review all (or selected) comments on the **current branch's** Pull Request, implement fixes where appropriate, then **reply under the specified comment** so the response appears in that comment thread on GitHub.

**Announce at start:** "I'm using the handle-pr-review-and-reply skill to process PR feedback and reply under each comment."

## When to Use

- User says "處理 PR 留言" / "審查 PR comment 並回覆" / "handle PR review and reply"
- Need to address review feedback on the **current branch's PR** and confirm under the comment
- Want to fix issues from review then reply in the same thread (not as a top-level PR comment)

## Prerequisites

- GitHub CLI (`gh`) installed and authenticated
- Current branch must have an open PR (e.g. `feature/generic-replay-land-v2` → PR #46)
- Repo is the one where the PR lives (e.g. `gmliao/swift-state-tree`)

## Principles

- **Reply under the comment:** Use the GitHub API to post a **reply** to the specific comment (same thread). Do not post a general PR comment.
- **Verify before implementing:** Follow technical evaluation from `Superpowers/receiving-code-review` — understand, verify in codebase, then implement and reply.
- **One reply per comment:** After handling a comment (fix or explanation), post exactly one reply under that comment summarizing what was done or why you deferred.

---

## Step 1: Ensure Current Branch Has a PR and Get IDs

**Get PR number and repo (must be on the branch that has the PR):**
```bash
gh pr view --json number,headRefName,baseRefName,url --jq '{number: .number, head: .headRefName, base: .baseRefName, url: .url}'
```

If this fails or shows "no pull requests found for branch", there is no PR for the current branch — tell the user to push and open a PR first.

**Get repo (owner/repo):**
```bash
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
echo $REPO
```
Example: `gmliao/swift-state-tree`

**Set PR number for later steps:**
```bash
PR_NUMBER=$(gh pr view --json number --jq '.number')
```

---

## Step 2: List All Review (Line) Comments for This PR

**List inline / line comments (file, line, body, comment id):**
```bash
gh api repos/$REPO/pulls/$PR_NUMBER/comments --jq '.[] | {id: .id, path: .path, line: .line, body: (.body | split("\n")[0:5] | join("\n")), user: .user.login}'
```

**List with full body (for implementing fixes):**
```bash
gh api repos/$REPO/pulls/$PR_NUMBER/comments --jq '.[] | {id: .id, path: .path, line: .line, body: .body, user: .user.login}'
```

If the user says "處理第 N 則" or "只處理 comment ID xyz", filter to that comment only.

---

## Step 3: For Each Comment — Understand, Fix, Then Reply Under That Comment

For **each** comment (or the one the user specified):

1. **Read & understand** the feedback (restate in your own words if needed).
2. **Verify** against the codebase (open the file, check context). If the suggestion is wrong or risky, do not implement; prepare a short technical explanation instead.
3. **Implement** the fix (or a justified alternative) if appropriate. After code changes:
   - Run **relevant** tests/lint for the touched code (e.g. `swift test --filter SnapshotValueDecodableTests` if you changed that file).
   - Before replying, run the **full** verification: `swift test` (all unit tests) and, if the change touches E2E/CLI/scripts, run the appropriate E2E (e.g. `cd Tools/CLI && ./test-e2e-ci.sh` or `./test-e2e-game.sh` per AGENTS.md). Fix any regressions before posting the reply.
4. **Reply under that comment** with a single, concise reply summarizing what you did (or why you did not change code). Use the **replies** endpoint so the reply appears **under the specified comment**.

**Reply API (must use this so the reply is under the comment):**
```bash
gh api --method POST "repos/$REPO/pulls/$PR_NUMBER/comments/$COMMENT_ID/replies" -f body="Your reply text"
```

**Important:**  
- `COMMENT_ID` is the numeric `id` from Step 2 (e.g. `123456789`).  
- Use the same `REPO` and `PR_NUMBER` as above.  
- The reply will show in the thread under that comment on GitHub.

**Reply content guidelines:**
- Be concise and technical (no performative praise).
- State what you changed: e.g. "Fixed: ..." or "Added test for ..."
- If you did not change code: e.g. "Left as-is because ..." or "Clarification: ..."
- Prefer English for the reply body unless the user explicitly asks for another language.

---

## Step 4: Optional — List Issue Comments (General PR Discussion)

If you need **top-level** PR discussion comments (not line comments):
```bash
gh api repos/$REPO/issues/$PR_NUMBER/comments --jq '.[] | {id: .id, body: (.body | split("\n")[0:3] | join("\n")), user: .user.login}'
```

To **reply to an issue comment** (same thread), use:
```bash
gh api --method POST "repos/$REPO/issues/$PR_NUMBER/comments" -f body="Your reply"  # This adds a new top-level comment; for threading, GitHub uses issue comments as a single thread, so new comment appears in PR conversation.
```

Note: For **inline review comments**, always use the **pulls comments replies** endpoint (Step 3). For **general PR conversation**, the issue comments endpoint is used; replying is typically "add another issue comment" (same thread in the UI).

---

## End-to-End Example

```bash
# 1) Resolve PR and repo
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
PR_NUMBER=$(gh pr view --json number --jq '.number')
if [ -z "$PR_NUMBER" ]; then echo "No PR for current branch"; exit 1; fi

# 2) List line comments
gh api repos/$REPO/pulls/$PR_NUMBER/comments --jq '.[] | {id: .id, path: .path, line: .line, body: (.body | split("\n")[0:2] | join(" "))}'

# 3) After implementing fix for comment 2700778279, reply under that comment
gh api --method POST "repos/$REPO/pulls/$PR_NUMBER/comments/2700778279/replies" \
  -f body="Done. Extracted the logic into \`selectReplayEventsToEmit()\` and added tests in GenericReplayLandDecodeTests."
```

---

## Checklist

- [ ] Confirm current branch has a PR (`gh pr view` succeeds).
- [ ] Use `repos/$REPO/pulls/$PR_NUMBER/comments/$COMMENT_ID/replies` to reply so the reply appears **under the specified comment**.
- [ ] One reply per comment after handling it (fix or explanation).
- [ ] Reply text is concise and technical; state what was done or why not.
- [ ] After code changes: run relevant tests for the changed area, then run full `swift test` and (if touch E2E/CLI) the relevant E2E suite; fix regressions before replying. Mention in reply what was run (e.g. "swift test + SnapshotValueDecodableTests pass" or "swift test + test-e2e-ci.sh pass").

## Integration with Other Skills

- Use **Superpowers/receiving-code-review** for how to evaluate feedback (verify, then implement or push back) before replying.
- Use **SwiftStateTree/view-pr-comments** to quickly list comments if you only need to view.
- Use **SwiftStateTree/reply-pr-comment** when you only need to reply to one comment without the full review-and-fix flow.
