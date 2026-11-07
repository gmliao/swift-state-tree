---
module: diagnostics and recording sinks
date: 2026-11-07
problem_type: gotcha
component: Foundation FileHandle
symptoms:
  - "The server dies with a Foundation fatal error (Linux) or an uncaught NSFileHandleOperationException (Darwin) while writing a diagnostic file"
  - "A full disk, a quota or a closed pipe ends the process instead of losing one line"
root_cause: nonthrowing_filehandle_write_traps_on_io_error
resolution_type: code_fix_and_rule
severity: high
tags:
  - foundation
  - filehandle
  - diagnostics
  - crash
  - linux
related:
  - "Sources/SwiftStateTreeTransport/Diagnostics/LandLifecycleLog.swift"
  - "https://github.com/gmliao/swift-state-tree/issues/263"
---

# `FileHandle.write(_: Data)` terminates the process on a write error

## Problem

The land lifecycle log (#262) first wrote its lines with `FileHandle.write(_: Data)`. Review found that the call can't report an error. A write that fails, for example ENOSPC on a full disk (reproduced on Linux with `/dev/full`), terminates the server. The write ran synchronously during land creation and removal, so a diagnostic file would have taken down the run it was measuring.

## Root cause

The non-throwing `write(_:)` predates Swift error handling:

- **swift-corelibs-foundation** (Linux) implements it as `try!` around the throwing write, so an I/O error is a fatal error.
- **Darwin** raises an Objective-C exception, which Swift can't catch.

The same holds for `seekToEndOfFile()`, `readDataToEndOfFile()` and the other non-throwing members. Their throwing replacements are `write(contentsOf:)`, `seekToEnd()`, `readToEnd()` and `close()`.

## Fix

- **Write and seek:** use `try handle.write(contentsOf:)`. Open with `open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)` and `FileHandle(fileDescriptor:closeOnDealloc:)`, so no seek is needed, and processes sharing a path append rather than overwrite.
- **After a failure:** the first one disables the sink, closes the handle and logs one error. Use an error, not a warning, when runs use `LOG_LEVEL=error`.
- **A path that can't be opened:** log one error naming the path, rather than silently giving no sink.

## Prevention

- Never call the non-throwing `FileHandle` I/O members in library code. That includes `FileHandle.standardOutput`/`standardError` in log handlers, where EPIPE has the same effect.
- Give each sink a closure seam (`write: (String) throws -> Void`), so a test can make the write fail and assert that the server keeps serving.
- The other uses in `Sources/` at the time of writing are listed in #263.
- The throwing write doesn't cover a closed pipe on its own. Writing to a pipe whose reader has gone raises SIGPIPE, and its default action ends the process before `EPIPE` is returned. SwiftNIO's protection differs by platform. On Linux it ignores SIGPIPE for the whole process the first time it creates a socket, so stdout and stderr are covered from then on, but not before. On Darwin it sets `F_SETNOSIGPIPE` on its own descriptors only, so stdout and stderr are never covered. Executables call `ProcessSignals.ignoreSIGPIPE()` first in `main` (#273). Test the write-error path with a read-only handle (EBADF) or `/dev/full` (ENOSPC), not with a closed pipe.
- A sink whose output is the product (an export a run was asked for) fails the run with a typed error (`ReevaluationExportWriteError`) instead of disabling itself: an incomplete export must not report success.
