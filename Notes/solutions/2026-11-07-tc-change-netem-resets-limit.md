---
module: measurement setup
date: 2026-11-07
problem_type: gotcha
component: tc-netem
symptoms:
  - "Unexpected drops in a delay-only netem cell after a profile change"
  - "netem's `dropped` counter grows at load although the setup gave a large `limit`"
root_cause: tc_qdisc_change_netem_resets_unstated_options_including_limit
resolution_type: tool_fix_and_method_rule
severity: medium
tags:
  - netem
  - tc
  - measurement-setup
  - methodology
related:
  - "Examples/GameDemo/ws-loadtest/scripts/impair.sh"
  - "Notes/plans/2026-11-07-network-impairment-experiment-design.md"
---

# `tc qdisc change ... netem` resets the options it isn't given, `limit` included

## Problem

The network impairment design sets each netem's queue `limit` well above the default of 1000 packets, since at 1500 connections with 50 ms of delay the default can overflow, and netem counts overflow drops in the same `dropped` counter as its loss drops. Profiles are applied in place with `tc qdisc change`. A change that names only the new delay or loss puts the limit back to 1000.

## Root cause

`tc` doesn't merge a `change` into the qdisc's current options. It parses the options given on the command line into a fresh option block, with netem's defaults for everything left out, and the kernel applies that block whole. A `limit` set at `add` time therefore lasts only until the first `change` that doesn't repeat it. The same goes for every other netem option: a change to `loss 100%` drops the delay a previous change set, unless it names it.

## Fix

`scripts/impair.sh` stores the limits at `setup` and appends them to every `change` it issues. A profile's arguments are its complete netem option set, not a delta: lifting changes back to P0's full set.

## Prevention

- Write every `tc qdisc change` for netem as the full option set, `limit` included.
- After a change, check `tc -s qdisc show` for the limit, not only the parameter just changed. The impairment timeline records that output before and after every change.
