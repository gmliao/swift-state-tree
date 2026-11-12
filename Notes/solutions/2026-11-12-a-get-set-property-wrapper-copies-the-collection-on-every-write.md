---
module: SwiftStateTree
date: 2026-11-12
problem_type: performance_collapse
component: sync-property-wrapper
symptoms:
  - "A tick that only updates entries in a dictionary field spends a large share of its time copying and destroying the element type (value-witness initializeWithCopy / destroy)"
  - "Dictionary.copy() or Array copies in a profile of code that writes one element at a time"
  - "Writing every element of a @Sync collection in a loop is quadratic in its size"
root_cause: wrapper_get_set_modify_copies_the_buffer
resolution_type: code_fix
severity: high
tags:
  - copy-on-write
  - property-wrapper
  - modify-accessor
  - sync
  - dirty-tracking
  - performance
related:
  - "#94"
  - "#519"
  - "#520"
---

# A get/set property wrapper copies the collection on every write

## Problem

Hero Defense's tick moves each monster, then writes it back: `state.monsters[id] = monster`, with `monsters` a `@Sync` dictionary. A profile of the tick showed `MonsterState`'s value-witness copy and destroy at about 12 % of cycles, with `Dictionary.copy()`, buffer frees and memmove close behind. The tick never copies the dictionary on purpose.

#94 had measured the same cause in isolation. In a release microbenchmark on Hero Defense's `monsters` dictionary, the first nested write cost (p50) 0.5 µs at 10 entries, 3 µs at 100, 29 µs at 1k and 277 µs at 10k. One write was O(N) in the collection's size.

## Symptoms

- In a profile, the element type's value-witness `initializeWithCopy` and `destroy` stand out, along with `Dictionary.copy()`, `swift_release` / the dealloc path, and memmove.
- The cost grows with the square of the collection's size when every element is written once per tick.
- No copy appears in the source: every write is a plain subscript assignment, a `removeValue`, an `append`, or an `inout` argument.

## Root cause

`Sync.wrappedValue` had only `get` and `set`:

```swift
public var wrappedValue: Value {
    get { _wrappedValue }
    set { _wrappedValue = newValue; _isDirty = true }
}
```

A wrapped property such as `state.monsters` is modified through the wrapper's `wrappedValue`. Without a `_modify`, that modify is a get into a temporary, the mutation on the temporary, and a set.

While the temporary exists, the wrapper's stored `_wrappedValue` still holds the collection's buffer, so the buffer isn't uniquely referenced. The collection's mutating subscript therefore copies the whole buffer: every element is copied, and the set then frees the old buffer, destroying every element.

Every write paid this, whatever its shape:
- `state.d[k] = v` and `state.d[k]?.field = v`;
- `removeValue` and `append`;
- `f(&state.d)`;
- the macro's `update<Field>`/`remove<Field>` helpers, which write through `wrappedValue`;
- a nested node's field, `state.child.field = v`, which copied the node.

This is not a debug-only effect. `SyncWrapperInPlaceTests`, run on the unfixed wrapper:
- **debug:** every copy check failed (a dictionary element, an array element, an `inout` argument, a nested node's field, the second write in a loop over the field);
- **release (`-O`):** the `inout` argument and the nested node's field were no longer copied, but a dictionary element, an array element and the loop's second write still were. The optimizer removes some of these copies, not the ones a game's element writes make.

## Fix

Give the wrapper an in-place modify, marking dirty before the yield:

```swift
_modify {
    _isDirty = true
    yield &_wrappedValue
}
```

**Marking before the yield is deliberate.** An access that a throw ends can skip the code after a `yield`: a write through the wrapper itself, `try f(&_field.wrappedValue)`, runs the code before the yield and `defer`s, not the code after it. A write made before a throw is kept (#87), so it must still be marked.

A write through the wrapped property, `try f(&state.field)`, did run the wrapper's code after the yield in a probe (Swift 6.4.2, `-Onone` and `-O`). The access path decides, so the mark must not depend on it.

Marking first keeps the old behavior, where `set` ran on the write-back. It also keeps the rule that any write access marks the field dirty, even one that changes nothing.

`SyncWrapperInPlaceTests` pins each write shape with an object that only the element holds (`isKnownUniquelyReferenced`). It also pins the dirty fields of each shape, including a write-then-throw through the property and through the wrapper itself. Only the wrapper path kills the mark-after-yield mutant.

## Prevention

- **A property wrapper that stores a value and observes writes needs `_modify`, not only `get`/`set`.** The same holds for any computed property in front of a stored collection: without `_modify`, every mutation through it copies the collection.
- **Test in-place writes with a uniqueness probe,** not with timing. Hold a `final class` instance inside the element and check `isKnownUniquelyReferenced` in a mutating method called through the property. A copy of the element, or of any collection or node holding it, makes the check false.
- **A loop that iterates the collection it writes holds the old buffer.** Only the first write may copy. Check that case by the storage address after two writes, since the box is shared with the iterator's copy.
- **Do side effects that must survive a throw before the `yield`** (or in a `defer`), never after it. Test the throw through the most direct access path (`&_field.wrappedValue`): a path through the synthesized property can hide a mark placed after the yield.
