---
module: SwiftStateTreeTransport
date: 2026-11-11
problem_type: platform_difference
component: opcode-json-decoder
symptoms:
  - "a decoder check passes on macOS and fails on every Linux CI leg"
  - "exactCount(NSDecimalNumber(string: \"7.0000000000000000001\")) returns 7 on Linux"
root_cause: corelibs_nsnumber_compare_uses_doubles
resolution_type: code_fix
severity: medium
tags:
  - linux
  - foundation
  - json
  - nsnumber
  - decimal
related:
  - "#487"
---

**Problem.** The row entry decoder refuses a slot, a generation or an op that is not exactly an integer. For a literal like `7.0000000000000000001`, whose double is integral, it compared the number with its integer: `number.compare(NSNumber(value: integer)) == .orderedSame`. That refused it on macOS and took it as 7 on Linux. An earlier change read this as "Linux's JSON parser hands a double", dropped the wire cases from the test, and wrote that into a comment.

**Root cause.** The parser was not the difference: `JSONSerialization` keeps such a literal as a decimal number on Linux too. The difference is `NSNumber.compare`. On Linux (swift-corelibs-foundation) it compares the two numbers as doubles, so the decimal's fraction is lost before the compare. Darwin compares the decimal exactly.

**Fix.** Compare decimal values: `number.decimalValue == Decimal(integer)`. It is exact on both platforms, for decimal numbers, integers and integral doubles. The wire cases came back.

**Prevention.**
- Don't rely on `NSNumber.compare`, or on `==` between NSNumbers, for exactness across platforms. Compare `decimalValue`, or the typed value read with its `objCType`.
- When a check differs between platforms, test the primitive in the pinned image before deciding which layer differs: `docker run --rm -v "$PWD":/w -w /w swift:6.2.4-noble swift main.swift` runs a one-file script without building the package.
- A comment that explains a platform difference states what was measured, so a wrong explanation can be checked.
