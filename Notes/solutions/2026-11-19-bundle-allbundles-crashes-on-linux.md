---
module: tests
date: 2026-11-19
problem_type: gotcha
component: test-support
symptoms:
  - "*** Program crashed: Bad pointer dereference at 0x0000000000000000 *** in a Linux test run"
  - "CFBundleGetAllBundles in libFoundation.so on the crashing thread's stack"
  - "a test that passed on macOS crashes the whole test process on Linux"
root_cause: bundle_enumeration_in_corelibs_foundation_dereferences_null
resolution_type: workaround
severity: medium
tags:
  - linux
  - foundation
  - bundle
  - test-support
  - cross-platform
related:
  - "#623"
---

**Problem.** In #623, `ReevaluationRunnerExitTests` looked for the test bundle's build products in `CommandLine.arguments + Bundle.allBundles.map(\.bundlePath)`. On macOS it passed. In CI's Linux `examples` job (the `swift:6.2.4-noble` image), the test process died with signal 11, which took the whole GameDemo suite down with it:

```
*** Program crashed: Bad pointer dereference at 0x0000000000000000 ***
  2 CFBundleGetAllBundles + 229 in libFoundation.so
  3 specialized static Bundle.allBundlesRegardlessOfType.getter + 21 in libFoundation.so
  4 static Bundle.allBundles.getter + 34 in libFoundation.so
  5 static ReevaluationRunnerExitTests.productsDirectory() + 85 in GameDemoPackageTests.xctest
```

Neither the macOS run nor the review caught it: the code reads as portable Foundation, and only Linux runs corelibs-foundation's `CFBundleGetAllBundles`.

**Root cause.** The crash is inside swift-corelibs-foundation's bundle enumeration, reached from `Bundle.allBundles`. Why it dereferences null there wasn't investigated: the call was removed instead. The other tests were running in parallel at the time, so concurrent use may play a part. That is unconfirmed.

**Fix.** The test reads the bundle from its own arguments only. On Linux, the `<name>.xctest` executable is `argv[0]`. On macOS, the testing helper is passed `<name>.xctest/Contents/MacOS/<name>`. The products directory is the parent of the path component that ends in `.xctest`. A failed lookup returns nil, and `#require` records it as an issue.

`dladdr(#dsohandle)`, the first replacement, doesn't compile on Linux: `Dl_info` and `dladdr` aren't visible from Swift's `Glibc` module, even with `import Glibc`, because glibc declares them only under `_GNU_SOURCE`. Using them would need a C shim.

**Prevention.**
- **Don't call `Bundle.allBundles` or `Bundle.allFrameworks` in code that runs on Linux,** tests included. To find a test's own build products, read the bundle path from `CommandLine.arguments`.
- **Don't count on `dladdr`/`Dl_info` from Swift on Linux** without a C target that defines `_GNU_SOURCE`.
- **A Foundation or libc API that passes on macOS isn't proven on Linux.** Before calling a test that touches process or bundle introspection portable, compile it in the pinned image: `docker run … swift@sha256:<digest>`, with `-j 2` on a small Docker VM. A 1 GB VM killed the compiler with signal 9 at the default parallelism.
