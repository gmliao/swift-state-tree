---
module: SwiftStateTree
date: 2026-11-12
problem_type: performance_collapse
component: sync-property-wrapper
symptoms:
  - "Value-witness copy and destroy of a node type (initializeWithCopy / destroy, outlined copy of an enum) in a profile of code that only copies plain data"
  - "MemoryLayout of a node type several times the size of its field values, and _isPOD false although every field is an Int or a fixed-point struct"
root_cause: per_instance_closure_enum_in_wrapper
resolution_type: code_fix
severity: medium
tags:
  - property-wrapper
  - value-witness
  - memory-layout
  - macro
  - static-storage
  - sync
  - performance
related:
  - "#519"
  - "#520"
---

# A closure in every wrapper makes every node type non-trivial

## Problem

Hero Defense copies `MonsterState` values all the time: a nearest-target scan reads each monster out of a `[Int: MonsterState]`, and `guard var m = state.monsters[id]` copies one out. A profile showed `MonsterState`'s value-witness copy and destroy, and `SyncPolicy`'s outlined copy and consume. The type holds eight fields of `Int`, `Position2`, `Angle` and `Float`, about 56 bytes of data.

## Symptoms

- `MemoryLayout<MonsterState>`: size 281, stride 288, `_isPOD` false.
- A copy of the struct goes through value witnesses, not a memcpy.

## Root cause

Each `@Sync` wrapper stored its own `policy: SyncPolicy<Value>` beside the value. `SyncPolicy` is an enum whose `.perPlayer`, `.masked` and `.custom` cases hold closures. So every wrapper held a possible reference, and every struct with a `@Sync` field had to retain and release it on each copy, whatever its field values were.

The policy is the same for every instance of a declaration. It was per-declaration data stored per value.

## Fix

`Sync` stores only the value and its dirty flag (#520). `@StateNodeBuilder` emits each field's policy once, as a static of the node type, written as the attribute's argument. The generated readers filter through `Self._syncPolicy_<field>`.

After the fix, `MonsterState` is size 89, stride 96 and POD. `PlayerState` goes from stride 296 to 112, also POD. `TurretState` goes from 232 to 88 and stays non-POD, because its `PlayerID` holds a `String`.

**A static stored property only where the type is provably not generic.** A generic type can't have one, and neither can a type nested in a generic type. The macro first tested only the struct's own generic parameters, so a node nested in a generic type, or in an extension of one, got a `static let` and failed to compile.

The check now walks `context.lexicalContext`:
- It accepts only non-generic `struct`, `class`, `enum` and `actor` declarations.
- It treats an `extension` as possibly generic, since its extended type's parameters aren't in the syntax.
- It treats a function, a closure or any other local context as possibly generic.

Everywhere else the policy is a static computed property, which evaluates the argument on every read.

## Prevention

- **Don't store per-declaration data in a property wrapper.** Anything the same for every instance belongs to the declaration: a static the macro emits, or a type-level table. A closure-holding enum in a wrapper makes every type that uses it non-trivially copyable.
- **Pin the layout of hot value types with a test:** `MemoryLayout<T>.size`, `.stride` and `_isPOD`. Pin it on a core fixture too, so the regression fails where it is introduced, not only in a game.
- **A macro that emits `static let` must check the whole lexical context,** not only the attached declaration's generic clause. When the context can't be proven non-generic (an extension, a local type), emit a computed static. Test it with a node nested in a generic type, in an extension and in a function.
- **Moving an expression from an instance initializer to a static changes when the value that's used is computed.**
  - In a stored static, it's computed once per type, at the first read, on whichever executor reads it.
  - In a computed static (the types the macro can't prove non-generic), it's computed on every read.
  - Here the attribute's argument is still evaluated at each init that initializes the field through the attribute (an initial value, or `self.x = …` in an init), because the wrapper's init takes it, and that value is discarded. So a side effect in it still runs per such init; only the value that filters moved. An init that builds the wrapper by hand doesn't evaluate it.
  - Pin each branch with a fixture that captures a counter: bump the counter between inits and before the first read, and use a type no other test reads.
- **A macro that reads an attribute's argument must pick it by label,** not by position. `@Sync(wrappedValue: 0, .broadcast)` is a legal property-wrapper spelling, and its first argument is the value. The policy is the unlabelled argument.

Code: `Sources/SwiftStateTreeMacros/StateNodeBuilderMacro.swift` (`isProvablyNonGeneric`, `generateSyncPolicyMembers`, `syncPolicyArgument`). Plan: [`../plans/2026-11-12-sync-policy-per-type.md`](../plans/2026-11-12-sync-policy-per-type.md).
