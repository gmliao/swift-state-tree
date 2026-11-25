# Autobahn|Testsuite against the NIO WebSocket server

Runs the [Autobahn|Testsuite](https://github.com/crossbario/autobahn-testsuite) fuzzing client,
the usual WebSocket conformance suite, against a server built on `NIOWebSocketServer` (#798).

This is test tooling. It changes nothing under `Sources/` or `Tests/`, and it is not a gate: the
server fails many cases today (see [Baseline](#baseline)), and the run reports them.

## Pieces

| File | Role |
|------|------|
| `Tools/AutobahnEcho/` | A SwiftPM executable: an echo server on `NIOWebSocketServer` and `WebSocketTransport`. It sends every message it receives back to its sender. |
| `fuzzingclient.json` | The suite's configuration: one server (`ws://127.0.0.1:9001`), every case except sections 9, 12 and 13. |
| `run.sh` | Builds and starts the harness, runs the suite's Docker image against it, stops the harness, prints a summary. |
| `summarize.py` | Reads `reports/servers/index.json`: a count per result, a table per section, the FAILED case ids. |
| `expected-failures.txt` | The cases that fail today, with a one-word cause each. |
| `../../.github/workflows/autobahn.yml` | Runs all of it in CI. |

## Running it

Needs Swift (the toolchain the repository pins), Docker and Python 3.

```bash
scripts/autobahn/run.sh
```

It builds the harness with `swift build`, starts it on `127.0.0.1:9001` (fixed, as in `fuzzingclient.json`), and runs
`crossbario/autobahn-testsuite` (pinned by digest) with `--network host`, so the container reaches
the harness on the host's loopback. A full run takes a few minutes. Reports land in
`scripts/autobahn/reports/` (git-ignored): `servers/index.html` is the suite's own overview,
`servers/index.json` the machine-readable one, `summary.txt` this directory's summary.

| Variable | Effect |
|----------|--------|
| `AUTOBAHN_ECHO_BIN` | A built `AutobahnEcho` executable. Skips the build (CI builds it in another job). |
| `AUTOBAHN_IMAGE` | The suite's Docker image (default: the pinned digest). |

Exit codes: `0` when the suite ran to the end (whatever it found), `3` for a missing executable,
`4` when the harness didn't start listening, `5` when the suite didn't run to the end, `6` when it
wrote no `index.json`. A failed case is not an error of the script.

To list the failed cases of a run, or to write `expected-failures.txt` again after a fix:

```bash
python3 scripts/autobahn/summarize.py scripts/autobahn/reports/servers/index.json --failed-only
python3 scripts/autobahn/summarize.py scripts/autobahn/reports/servers/index.json --expected-failures
```

## What the harness is

`AutobahnEcho` registers a `FrameKindTransportDelegate` on a `WebSocketTransport` and sends each
message back to its session in the frame type it arrived in (`sendSessionFrames` with the
message's kind, #813), so the suite measures the server's rule: a frame's type follows its bytes. It listens on `127.0.0.1` (the port is the first
argument, else `AUTOBAHN_ECHO_PORT`, else 9001), accepts every path, takes the default limits except
a 16 MiB frame limit (`maxFrameSize`, the default), and stops on SIGINT or SIGTERM.

Before #813 the server sent every message as a binary frame, so every text-echo case failed as
`text-as-binary`. Since #813 a text message comes back as text, and the server checks a text
message for UTF-8 once it is complete, failing an invalid one with 1007.

## Reading a result

Every case has two verdicts: `behavior` (what the server echoed) and `behaviorClose` (how the
connection ended). `summarize.py` takes the worse of the two, ordered FAILED, UNIMPLEMENTED,
NON-STRICT, INFORMATIONAL, OK. INFORMATIONAL is a case the suite doesn't judge (here 7.1.6, 7.13.1 and 7.13.2); it is not a failure.

`behaviorClose` can carry Autobahn's close-specific classes, which `summarize.py` maps before the
comparison: `UNCLEAN` (Autobahn: `case_failed`) → FAILED; `WRONG CODE` (Autobahn:
`case_non_strict`) → NON-STRICT; `FAILED BY CLIENT` (Autobahn: `case_almost`, reported here as
NON-STRICT) → NON-STRICT.

Sections run: 1 framing, 2 pings and pongs, 3 reserved bits, 4 opcodes, 5 fragmentation, 6 UTF-8
handling, 7 close handling, 10 miscellaneous. Not run: 9 (limits and performance, long and
dependent on the machine), 12 and 13 (permessage-deflate).

## Baseline

`expected-failures.txt` lists the cases that failed on the baseline run (the Autobahn workflow's
run on #813's change: 11 FAILED, 9 NON-STRICT, 3 INFORMATIONAL, 224 OK of 247). Each cause is a
guess from `summarize.py`. Causes without a `guess:` prefix (`text-as-binary`, none since #813)
are diagnosed from the case report. Causes with `guess:` are derived from the section number alone — the section's
usual failure mode — and may be wrong for individual cases; file separate issues when a cause is
confirmed.

| Cause | Cases | What the suite saw |
|-------|-------|--------------------|
| `guess:fragmentation` | 10 | Section 5 (5.9–5.18): a bad fragment sequence is not failed. Diagnosed from the reports: the reassembler ignores a continuation with nothing to continue, and a new text or binary opener replaces an unfinished message, where RFC 6455 fails the connection with 1002. |
| `guess:utf8` | 1 | 6.4.4: one invalid frame sent in three chops. Diagnosed: NIO's frame decoder hands over a frame only once all of it has arrived, so the check can't fail fast inside one frame; the suite times out and closes first. 6.4.1–6.4.3, the same payload across frames, are NON-STRICT for the same reason (the check runs on the complete message). |

A case that fails and isn't listed is a regression, a listed case that passes is a fix: update the
file with the second command above in the same change.
