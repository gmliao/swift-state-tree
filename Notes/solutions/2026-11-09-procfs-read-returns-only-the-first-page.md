---
module: SwiftStateTree
date: 2026-11-09
problem_type: gotcha
component: hardware-info
symptoms:
  - "A record's hardware info says 'CPU Cores: 3' on a Linux host with 12 CPUs"
  - "A value read from /proc stops partway through the file"
root_cause: foundation_reads_one_page_of_a_procfs_file
resolution_type: design_rule
severity: low
tags:
  - linux
  - procfs
  - foundation
  - measurement
  - metadata
related:
  - "#345"
  - "Sources/SwiftStateTree/Core/HardwareInfo.swift"
---

# `String(contentsOfFile:)` on a Linux procfs file returns only the first page

## Problem

On the pinned image (swift:6.2.4-noble) in a container with 12 CPUs, `HardwareInfoCollector.collect()` reported `cpuCores` 3. It counts the `processor` lines of `/proc/cpuinfo`. The container's cgroup and cpuset didn't limit anything (`cpu.max` was `max 100000`, the cpuset `0-11`), and `ProcessInfo.processorCount` said 12.

## Root cause

procfs files report a size of 0 and are generated as they are read. On Linux, Foundation's `String(contentsOfFile:)` and `FileManager.default.contents(atPath:)` returned only the first page of such a file: 4074 of 16302 bytes of `/proc/cpuinfo`. That's 3 processor blocks of 12. Measured in the container:

```
String(contentsOfFile:) bytes 4074 processors 3
FileManager.contents bytes 4074
processorCount 12 active 12
```

Whatever lies past the first page is missing silently. No error is raised, and the string is valid.

## Fix

Not fixed yet (#345): `HardwareInfo.cpuCores` only reaches re-evaluation record metadata, so it is a deferred bug. The planned fix counts CPUs with `ProcessInfo.processInfo.processorCount`. The CPUs available to the process (affinity mask, cgroup) go in a separately labelled field. Any procfs file goes through a reader that reads until EOF (`FileHandle.readToEnd()`).

## Prevention

- Read a procfs (or sysfs) file until EOF, never with a size-based read. A value near the start of the file can't be trusted to stay there on a bigger machine.
- Count CPUs with `ProcessInfo`, not by parsing `/proc/cpuinfo`.
- The procfs reads with `String(contentsOfFile:)` in the repository on 2026-11-09, and why each is or isn't affected:

| Read | File, size here | What it takes | Affected |
|---|---|---|---|
| `HardwareInfo.swift:106` | `/proc/cpuinfo`, 16 KB | count of `processor` lines, the model | **yes**: the count (record metadata only; #345) |
| `NIOWebSocketServer.readAffinityMask` (`:106`) | `/proc/self/status`, 1.4 KB | `Cpus_allowed_list` (the server's event-loop count) | no: the whole file fits one page |
| `NIOWebSocketServer.readSystemFile` (somaxconn) | `/proc/sys/net/core/somaxconn`, one line | the listen backlog cap | no |
| `LoadTestPacing/ProcessUsage.swift:52` | `/proc/self/statm`, one line | resident memory | no |
| EncodingBenchmark `readTextFile`, `ResultsMetadata.readTextFile` | `/proc/sys/kernel/osrelease`, `/proc/1/cgroup`, `/proc/cpuinfo` | WSL and container detection; the first `model name` and `cpu cores` | no: those sit in the first page. The results' CPU counts come from `ProcessInfo` |

The status file is on a measured path (the NIO server's CPU count). It's correct today only because the file fits one page, so move it to the EOF reader with the hardware-info fix.
