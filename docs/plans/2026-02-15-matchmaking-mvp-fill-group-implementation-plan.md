# Matchmaking MVP 湊滿一組 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement "fill group" matchmaking: tickets in same queueKey are grouped when they sum to target size (minGroupSize～maxGroupSize). One allocate per group, N JWTs per group. Single process first; ROLE/Pub/Sub later.

**Architecture:** Keep existing MatchQueuePort (BullMQ). Extend MatchStrategyPort with `findMatchableGroups`. MatchmakingService processes groups: allocate once, issue N JWTs (one per ticket), push to each ticketId. Queue config (min/max/relax) from queueKey parse or env.

**Tech Stack:** NestJS, BullMQ, Redis, existing provisioning/JWT, ws.

**Reference:** `docs/plans/2026-02-15-matchmaking-mvp-fill-group-design-analysis.md`

---

## Task 1: Add QueueConfig and queueKey parsing

**Files:**
- Create: `Packages/control-plane/src/matchmaking/queue-config.ts`

**Step 1: Create queue config**

Create `Packages/control-plane/src/matchmaking/queue-config.ts` with QueueConfig interface, parseGroupSizeFromQueueKey, getQueueConfig.

**Step 2: Run tests**

Run: `cd Packages/control-plane && npm test`
Expected: Pass (new file has no breaking changes).

**Step 3: Commit**

```bash
git add Packages/control-plane/src/matchmaking/queue-config.ts
git commit -m "feat(matchmaking): add QueueConfig and queueKey parsing"
```

---

## Task 2: Extend MatchStrategyPort with findMatchableGroups

**Files:**
- Modify: `Packages/control-plane/src/matchmaking/match-strategy.port.ts`
- Modify: `Packages/control-plane/src/matchmaking/strategies/default.strategy.ts`

**Step 1: Add MatchableGroup and findMatchableGroups to port**

**Step 2: Implement findMatchableGroups in DefaultMatchStrategy** (returns each matchable ticket as single-ticket group for backward compat)

**Step 3: Run tests**

Expected: Pass.

**Step 4: Commit**

```bash
git commit -m "feat(matchmaking): extend MatchStrategyPort with findMatchableGroups"
```

---

## Task 3: Implement FillGroupStrategy

**Files:**
- Create: `Packages/control-plane/src/matchmaking/strategies/fill-group.strategy.ts`
- Modify: `Packages/control-plane/src/matchmaking/matchmaking.module.ts`

**Step 1: Create FillGroupStrategy** with findMatchableGroups that greedily forms groups (FIFO, min/max, relaxAfterMs).

**Step 2: Switch module to FillGroupStrategy**

**Step 3: Run tests**

Expected: May fail until Task 4 (MatchmakingService still uses findMatchableTickets).

**Step 4: Commit**

```bash
git commit -m "feat(matchmaking): add FillGroupStrategy"
```

---

## Task 4: Update MatchmakingService to process groups

**Files:**
- Modify: `Packages/control-plane/src/matchmaking/matchmaking.service.ts`

**Step 1: Rewrite runMatchmakingTick** to use findMatchableGroups, processGroup.

**Step 2: Add processGroup** - allocate once per group, issue one JWT per ticket (members[0]), return one AssignmentResult per ticket.

**Step 3: Remove processMatch** (replaced by processGroup).

**Step 4: Run tests**

Expected: All pass.

**Step 5: Commit**

```bash
git commit -m "feat(matchmaking): process groups, allocate once per group"
```

---

## Task 5: Update tests and verify

**Files:**
- Modify: `Packages/control-plane/test/matchmaking.service.spec.ts`

**Step 1: Add test** for 3 solo tickets in same queueKey forming one group (hero-defense:3v3).

**Step 2: Run full test suite**

**Step 3: Commit**

```bash
git commit -m "test(matchmaking): add fill-group scenario"
```
