---
module: measurement setup
date: 2026-11-07
problem_type: gotcha
component: kernel-socket-metrics
symptoms:
  - "Every network namespace reports the same TCP `mem` in /proc/net/sockstat"
  - "A per-namespace socket memory metric moves in the healthy namespace when only the impaired one is shaped"
root_cause: sockstat_mem_orphan_alloc_are_global_counters
resolution_type: method_rule
severity: medium
tags:
  - netns
  - sockstat
  - kernel
  - measurement
  - methodology
related:
  - "Notes/plans/2026-11-07-network-impairment-experiment-design.md"
  - "Examples/GameDemo/ws-loadtest/src/sockstat.ts"
---

# `/proc/net/sockstat` TCP `mem` is host-wide, not per namespace

## Problem

The network impairment design planned a per-namespace `sockstatMem` metric: TCP buffer memory in each client namespace, to tell an impaired client's kernel backlog apart from a healthy one's. Reading `/proc/net/sockstat` inside each namespace would have produced the same number for all of them.

## Root cause

In the TCP line of `/proc/net/sockstat`, only `inuse` and `tw` come from the reading namespace. `orphan`, `alloc` and `mem` are global counters, for the whole host (`net/ipv4/proc.c`, `sockstat_seq_show`: `sock_prot_inuse_get(net, ...)` against `tcp_orphan_count_sum()`, `tcp_sockets_allocated` and `proto_memory_allocated(&tcp_prot)`). The file is per namespace, so the global fields look per namespace too.

## Fix

The sampler (`ws-loadtest/src/sockstat.ts`) records `mem` once per sample, as `hostTcpMemPages`. For each namespace it runs `ss -tnH state established` there, and sums the sockets' `Recv-Q` and `Send-Q`, with the largest of each. These are the bytes that namespace's sockets hold. The design's § 5 now has `sockstatMem` (host-wide) and `socketQueues` (per namespace).

## Prevention

- Before treating a `/proc/net/*` field as per namespace, check that the kernel reads it from `struct net`. A file being per namespace doesn't make every field in it per namespace.
- For per-namespace socket state, sum per-socket values (`ss`, `sock_diag`) in that namespace.
