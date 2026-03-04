# handle-pr-review-and-reply

Review PR comments on the **current branch's** PR, implement fixes where appropriate, and **reply under each specified comment** so the response appears in that thread on GitHub.

## When to use

- User says "處理 PR 留言" / "審查 PR comment 並回覆" / "handle PR review and reply"
- Need to address review feedback and confirm **under the comment** (not as a top-level PR comment)

## Prerequisites

- GitHub CLI (`gh`) installed and authenticated
- Current branch has an open PR

## Steps

### 1. Resolve PR and repo

```bash
gh pr view --json number,headRefName,url --jq '{number: .number, head: .headRefName, url: .url}'
```

If "no pull requests found for branch", stop and tell the user to push and open a PR.

```bash
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
PR_NUMBER=$(gh pr view --json number --jq '.number')
```

### 2. List review (line) comments

```bash
gh api repos/$REPO/pulls/$PR_NUMBER/comments --jq '.[] | {id: .id, path: .path, line: .line, body: (.body | split("\n")[0:5] | join("\n")), user: .user.login}'
```

If the user specified a comment ID or "only the first one", filter to that comment.

### 3. For each comment: understand → fix → reply under that comment

For each comment (or the one the user specified):

1. **Read** the feedback and restate if needed.
2. **Verify** against the codebase. If the suggestion is wrong or risky, do not implement; prepare a short technical explanation.
3. **Implement** the fix (or justified alternative). After code changes:
   - Run **relevant** tests/lint for the touched code.
   - Run **full** verification before replying: `swift test`; if the change touches E2E/CLI/scripts, also run the appropriate E2E (e.g. `cd Tools/CLI && ./test-e2e-ci.sh` or `./test-e2e-game.sh`). Fix any regressions before replying.
4. **Reply under that comment** with one concise reply (what you did or why you did not change). Use the **replies** endpoint so the reply appears **under the specified comment**:

```bash
gh api --method POST "repos/$REPO/pulls/$PR_NUMBER/comments/$COMMENT_ID/replies" -f body="Your reply text"
```

- `COMMENT_ID` = numeric `id` from step 2.
- Reply: concise, technical; state what changed or "Left as-is because ...". Prefer English unless user asks otherwise.

### 4. Checklist

- [ ] Current branch has a PR.
- [ ] Use `.../comments/$COMMENT_ID/replies` so the reply appears **under that comment**.
- [ ] One reply per comment after handling it.
- [ ] After code changes: run relevant tests, then full `swift test` and (if touch E2E/CLI) relevant E2E; fix regressions before replying. Mention in reply what was run.

## Quick reference

```bash
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
PR_NUMBER=$(gh pr view --json number --jq '.number')
# List comments:
gh api repos/$REPO/pulls/$PR_NUMBER/comments --jq '.[] | {id: .id, path: .path, line: .line, body: (.body | split("\n")[0:2] | join(" "))}'
# Reply under comment (replace COMMENT_ID and body):
gh api --method POST "repos/$REPO/pulls/$PR_NUMBER/comments/COMMENT_ID/replies" -f body="Done. ..."
```

## Integration

- Evaluate feedback rigorously (verify before implementing, push back if wrong): apply **receiving-code-review** principles.
- To only view comments: `gh pr view --comments` or list with the `gh api` command above.
- To only reply once without full flow: use the `replies` POST with the desired `COMMENT_ID` and `body`.
