---
title: "'Corrupted JSON' in a Swift build log is the macro plugin's exit, not the build; read for 'Failed frontend command' and the 'error:' lines"
module: build and CI
date: 2026-11-27
problem_type: measurement_pitfall
component: ci-log-triage
symptoms:
  - "Internal Error: DecodingError.dataCorrupted: Data was corrupted. Debug description: Corrupted JSON. Underlying error: unexpected end of file"
  - "a red Linux job whose log shows that line just before 'Failed frontend command:'"
  - "the line repeated dozens of times in a build that ends 'Build complete!'"
root_cause: a_macro_plugin_exit_line_read_as_the_build_failure
resolution_type: design_rule
severity: medium
tags:
  - ci
  - build-log
  - macros
  - swift-syntax
  - triage
related:
  - "#937"
  - "#935"
  - "#925"
---

**Problem.** Two CI failures (#925, #935) were blamed on a swift-build JSON corruption (a truncated output-file map, a shared cache) because the log shows this line just before the failure:

```
Internal Error: DecodingError.dataCorrupted: Data was corrupted. Debug description: Corrupted JSON. Underlying error: unexpected end of file
```

It wasn't the cause of either. Two sessions read it that way on the same day.

**Symptoms.** The line shows up in nearly every build, on Linux and on macOS, locally and on CI. On 2026-11-27 it appeared in 64 of 67 completed CI runs, about 30 times per full build, and in builds that end `Build complete!`.

**Root cause.** The line is printed by our macro executables (`SwiftStateTreeMacros`, `SwiftStateTurnsMacros`). swift-syntax's plugin message loop (`SwiftCompilerPluginMessageHandling/CompilerPluginMessageHandler.swift`, `handleNextMessage`) prints `Internal Error: …` and calls `exit(1)` when a message fails to decode. Fed by hand, the plugin prints exactly this message for a complete frame (an 8-byte length header and that many bytes) whose JSON is empty or cut short. A closed stdin exits cleanly, and a pipe that closes inside a frame gives `read(2) reached end-of-file` instead:

```
printf '\0\0\0\0\0\0\0\0' | .build/debug/SwiftStateTreeMacros   # the line, rc 1
```

So the host sends such a frame, most likely as a frontend finishes, after its last expansion; the line comes right after one compile task's diagnostics. Which message it is stays open in #937. No file, filelist, output-file map or cache is involved: the line also shows up without any cache.

What actually failed each job:
- #935 (run 45925312935) had a real compile error, `ReplayServerInputDecodeFailureTests.swift:107:11: error: cannot find 'pthread_getattr_np' in scope`. The `Failed frontend command:` after the line was that file's compile command.
- #925 (run 45846915801, attempt 1) built (`Build complete!`). It failed in a test step: `the test "A config built with init takes TYPED_LEAF_VALUES" did not run`.

**Fix.** None in the build. The triage rule below.

**Prevention.**
- Treat this line as noise. Judge a build by `Build complete!`, the `error:` lines from the compiler (`<file>:<line>:<col>: error:`) and `Failed frontend command:`. Read the command below that last line: it names the file whose compile failed.
- For a red job, find the step that failed (`##[error]`) before reading the build output. A job can build and fail in a later step, such as a test that didn't run.
- Don't grep build logs for `error:` alone to decide a verdict: `Internal Error:` matches it (#937's earlier comment).
