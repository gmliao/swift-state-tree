---
title: "A macro diagnostic defers when it can't read the spelling with certainty"
module: SwiftStateTreeMacros
date: 2026-11-24
problem_type: design_rule
component: payload-macro
symptoms:
  - "@Payload refuses a generic payload that compiles: `where T == Int`, `` where `T`: PlainData ``, or a field typed `Namespace.T`"
  - "generic parameter 'T' is stored in 'value'; a payload must declare 'T: PlainData' on correct code"
root_cause: a_syntactic_diagnostic_refused_spellings_it_could_not_read_instead_of_leaving_them_to_the_type_checker
resolution_type: design_rule
severity: medium
tags:
  - macros
  - diagnostics
  - swift-syntax
  - generics
  - false-positive
related:
  - "#790"
  - "#782"
---

# A macro diagnostic defers when it can't read the spelling with certainty

## Problem

`@Payload` refuses a generic payload that stores a parameter without `T: PlainData`, naming the parameter and the field. The type checker refuses the same code anyway, with a vaguer message, so the macro's diagnostic only buys a clearer error. In review of #790 it refused three declarations that compile:

- a same-type requirement, `struct E<T>: ServerEventPayload where T == Int { let value: T }`: no conformance requirement named `T`, so "no constraint" was assumed;
- a backticked parameter in `where`, `` where `T`: PlainData ``: the requirement's left side was compared as written (`` `T` ``) with the normalized parameter name (`T`);
- a member type spelled like the parameter, `let value: Namespace.T`: any token named `T` in the field's type counted as storing `T`.

## Root cause

A macro sees syntax, not types. The check was written as "refuse unless I see the constraint", so every spelling it didn't anticipate became a refusal. For a diagnostic whose only job is a better message than the compiler's, that is the wrong default: a missed message costs a vaguer error, while a false refusal breaks correct code and can't be worked around.

## Fix

The check refuses only what it reads with certainty (#790):

- names are compared normalized (backticks removed) on both sides;
- a field stores `T` only through an `IdentifierTypeSyntax` reference to it (`T`, `[T]`, `Box<T>`). A member type's name (`Namespace.T`) and a member type's base (`T.Element`) don't count;
- any same-type or layout requirement that names the parameter defers the decision to the compiler, as does a constraint spelled with an unknown name (an alias, another protocol).

`PayloadExtensionRoleTests.unconstrainedParameter` has a case per shape.

## Prevention

- A syntactic diagnostic that duplicates a type-checker error refuses only the shapes it fully reads, and defers everything else. Write the rule as "refuse when I can read that it's wrong", not "refuse unless I can read that it's right".
- Compare identifiers normalized (`token.identifier?.name`), never by `trimmedDescription`.
- Match type references with `IdentifierTypeSyntax`, not by token: a token match also hits member names, labels and keywords.
- For each such diagnostic, add tests for the spellings it must leave alone, not only for the one it refuses.
