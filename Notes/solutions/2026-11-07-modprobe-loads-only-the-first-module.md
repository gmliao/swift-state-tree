---
module: measurement setup
date: 2026-11-07
problem_type: gotcha
component: host-kernel-modules
symptoms:
  - "`modprobe sch_netem sch_prio cls_u32` succeeds, but `tc qdisc add ... prio` or `tc filter ... u32` later fails with an unknown kind"
  - "`lsmod` shows only the first of several modules named on one modprobe line"
  - "A traffic-shaping setup that worked yesterday fails after a WSL restart"
root_cause: modprobe_takes_one_module_and_reads_the_rest_as_parameters
resolution_type: tool_fix_and_method_rule
severity: low
tags:
  - kernel-modules
  - netem
  - tc
  - wsl
  - measurement-setup
related:
  - "Notes/plans/2026-11-07-network-impairment-experiment-design.md"
---

# `modprobe` loads only the first module named

## Problem

The network impairment experiment needs the `sch_netem`, `sch_prio` and `cls_u32` modules on a kernel that builds them as `=m`. `modprobe sch_netem sch_prio cls_u32` exited without an error, yet it loaded only `sch_netem`. Loading the other two took a second attempt.

## Root cause

`modprobe <module> [parameters...]` takes one module name. Every later word is read as a parameter of that module, and unknown parameters don't fail the command. `modprobe -a` is the form that loads every name given.

Separately, loaded modules aren't persistent: a `wsl --shutdown` or a Windows restart drops them, so a setup that passed once can fail on the next session.

## Fix

The design's host checklist (§ 10, step 1) uses `modprobe -a sch_netem sch_prio cls_u32` and checks each module with `lsmod`. The acceptance smoke (step 4) checks `/proc/modules` for every module the kernel builds as `=m`, before anything else, every time it runs.

## Prevention

- Load several modules with `modprobe -a`, and check each one in `lsmod` or `/proc/modules`. Don't rely on the exit code.
- A script that needs kernel modules checks they are loaded at its start, not once at setup time, because a VM restart drops them.
