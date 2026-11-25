---
module: SwiftStateTreeNIO
date: 2026-11-21
problem_type: gotcha
component: listening-socket
symptoms:
  - "A \"port already in use\" test hangs instead of failing: `host.run()` never throws"
  - "On Windows two servers bind the same port and both start without an error"
root_cause: so_reuseaddr_lets_two_sockets_share_a_port_on_windows
resolution_type: code_fix
severity: medium
tags:
  - windows
  - sockets
  - so-reuseaddr
  - port-in-use
  - cross-platform
  - testing
  - hang
related:
  - "#785"
---

# `SO_REUSEADDR` lets two sockets share a port on Windows

## Problem

`NIOWebSocketServer` set `SO_REUSEADDR` on its listening socket. On Linux and macOS that is the usual option for a server: a restarted server can bind a port whose previous connections are still in `TIME_WAIT`, and a port with a live listener still fails with "address in use". On Windows the same option means something else.

## Symptoms

- `NIOLandHostTests.testMiddlewareCancellationOnStartupFailure` and `testMiddlewareOnShutdownOnStartupFailure` pre-bind a port (also with `SO_REUSEADDR`) and expect `host.run()` to throw. On Windows `run()` bound the same port, started serving and never returned, so each test hung until its runner killed it. Run as a whole module the hang looked like a stuck test process with an empty log.
- No error anywhere: the second server simply started.

## Root cause

Two sockets that both set `SO_REUSEADDR` can bind the same address and port at the same time on Windows. A minimal two-socket bind on `127.0.0.1` shows it: both set the option, the second `bind` succeeds; neither set it, the second `bind` fails with `WSAEADDRINUSE` (10048). Besides the hung test, a second server (or another process) could silently share or take over the listener's port.

## Fix

On Windows the listener requests exclusive use of its port with `SO_EXCLUSIVEADDRUSE` instead (defined as `~SO_REUSEADDR`; NIO has no named constant for it). The second `bind` then fails with "address in use" even when the other socket sets `SO_REUSEADDR`. Linux and macOS are unchanged. The one `#if os(Windows)` is unavoidable: the same option name means different things there.

Not setting any option would also fail the duplicate bind, but a later socket that sets `SO_REUSEADDR` could still bind over the listener; exclusive use closes that. Landed in #785 (merge commit `68f4d35b`).

## Prevention

- Don't set `SO_REUSEADDR` on a listener that must own its port on Windows. Treat it as "share this port", not "rebind after a restart".
- A test of the "port in use" path needs a real, listening socket on the port; the two tests above pin the behavior (on Windows they hang if the listener is allowed to share).
- A test that expects an error from something that runs forever when it unexpectedly succeeds should have a time limit, so a wrong success fails instead of hanging.
