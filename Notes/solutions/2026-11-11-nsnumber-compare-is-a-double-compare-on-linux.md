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

**Fix.** Compare decimal values for a decimal number only: `if let decimal = number as? NSDecimalNumber { guard decimal.decimalValue == Decimal(integer) }`. Every other number's integral double is already exact. The wire cases came back.

**The first fix was wrong too.** It compared `number.decimalValue == Decimal(integer)` for every number. On Linux, `decimalValue` of an NSNumber that isn't an NSDecimalNumber is `Decimal(doubleValue)`, which is inexact for some integers from 1475741 on (2147483646 comes out as `…000000256`). Valid slots and generations were refused, from JSON and MessagePack alike. The platform check had passed because it only tried small numbers and `Int32.max`, which happens to be exact.

**Prevention.**
- Don't rely on `NSNumber.compare`, on `==` between NSNumbers, or on `decimalValue` of a non-decimal NSNumber, for exactness on Linux. Compare `decimalValue` only for an `NSDecimalNumber`.
- When a check differs between platforms, test the primitive in the pinned image before deciding which layer differs: `docker run --rm -v "$PWD":/w -w /w swift:6.2.4-noble swift main.swift` runs a one-file script without building the package.
- A platform check sweeps the input range (every integer up to a few million, then a stride to the limit), not a few hand-picked values: boundaries like `Int32.max` can be exact by accident.
- A comment that explains a platform difference states what was measured, so a wrong explanation can be checked.
