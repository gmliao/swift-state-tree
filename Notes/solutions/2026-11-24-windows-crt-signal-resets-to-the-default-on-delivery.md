---
module: SwiftStateTree
date: 2026-11-24
problem_type: gotcha
component: shutdown-signals
symptoms:
  - "The second Ctrl-C on Windows ends the process with 0xC000013A instead of 128 + SIGINT"
  - "The second Ctrl-Break ends it with 0xC000013A instead of 128 + SIGBREAK"
  - "A signal handler installed with signal() runs once and the next signal takes the default action"
root_cause: ucrt_signal_resets_the_handler_to_sig_dfl_before_each_call
resolution_type: code_fix
severity: medium
tags:
  - windows
  - signals
  - crt
  - shutdown
  - ctrl-c
related:
  - "#785"
---

# The Windows CRT `signal()` resets to the default on delivery: re-arm in the handler

## Problem

`ProcessSignals.shutdownSignals(_:)` promises that a second signal ends the process at once, with exit status `128 + signal`, so a shutdown that hangs doesn't hold up an operator who presses Ctrl-C twice. On POSIX the handler is installed with `sigaction`, which keeps it installed. The Windows port used the C runtime's `signal(signal, handler)`, which does not.

## Root cause

The universal C runtime gives `signal()` System V semantics: before it calls the handler for a caught signal, it resets that signal to `SIG_DFL`. The first Ctrl-C reached the handler and started the shutdown. The second found `SIG_DFL` and took the runtime default, which ends the process with `STATUS_CONTROL_C_EXIT` (`0xC000013A`); the reader never counted a second delivery, so `_exit(128 + signal)` never ran. Ctrl-Break behaved the same. The reader also records a signal as `installed` after the first call, so nothing armed it again.

A related slip hid the failure: `signal()` returns `SIG_ERR` (`(void (*)(int))-1`) for an unsupported signal, Swift doesn't import that name, and the result was ignored, so a failed install was recorded as installed.

## Fix

On Windows the handler arms the signal again as its first statement (`ucrt.signal(signal, shutdownSignalHandler)`), the usual idiom for the C runtime, and then writes the byte to the pipe. `install` compares the result with `-1` (by bit pattern) and stops with `preconditionFailure`, as the POSIX path does when `sigaction` fails. A second signal that arrives in the few instructions before the handler re-arms still takes the default; for a person at a keyboard that window is not reachable.

A probe program that arms `shutdownSignals()`, prints the first signal and then hangs showed the change on Windows 11 with Swift 6.4.3: two Ctrl-C ended it with exit status 130 (0x82), two Ctrl-Break with 149 (128 + 21); before the change, both pairs ended it with 0xC000013A.

## Prevention

- **A handler installed with `signal()` on Windows re-arms itself**, or the code uses `SetConsoleCtrlHandler` for console events. A port of signal code that counts deliveries needs a test, or a probe run, that sends two.
- **Check `signal()`'s result** against `SIG_ERR` before recording the signal as installed.
- The shutdown-signal tests are POSIX-only (they use `kill`, `posix_spawn` and `SIGUSR2`), so the Windows path is checked by hand: start a program that hangs after the first signal and send two Ctrl-C events to its console.
