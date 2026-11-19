# ``SwiftStateTurns``

Change an actor's state only in synchronous steps; everything asynchronous is a request whose result comes back as an input.

## Overview

An actor's methods run one at a time. But every `await` inside a method lets other calls run first. State that a method checked before an `await` may be stale after it. A method that changes state after an `await` acts on a world that has moved on.

A *turn* is the actor's unit of work: one job, run to completion, with no suspension in it. This is the actor-model sense of the word, not a turn in a game. This target makes every change to an actor's state happen inside one turn, as a synchronous *step* of a value-type machine. A step is one call of the machine's handler with one input.

## How the pieces fit

@Image(source: "turn-core-layers.svg", alt: "TurnActor, the shell, holds TurnCore, the mechanics, which holds TurnMachine, the pure state machine. Callers send inputs in with send and sendAndWait; flush sends outputs out; effects run off the actor; results, deadlines and timers come back as inputs.")

- term ``TurnMachine``: The pure state machine. A step takes the state and one input. It returns the new state, plus outputs, replies and effects. A step is synchronous, stores only plain data, and can't `await`.
- term ``TurnCore``: The mechanics. It keeps the *queue* (inputs waiting behind work in flight), *keys* and their *generations* (which work is still wanted), *holds* and their deadlines (what makes later inputs wait), and timers.
- term ``TurnActor``: The shell. `send` and `sendAndWait` bring inputs in. `perform` runs effects off the actor. `flush` sends outputs out.

An effect's result, a deadline or a timer comes back as a new input. Each entry into the actor (a `send`, a `sendAndWait`, a result coming back) runs one *batch*: the steps that entry causes. `maxReleasesPerBatch` caps how many queued inputs a hold's release lets step in one batch. There is no run loop waiting between entries. The pattern is known as "functional core, imperative shell". Elm's `Cmd`/`Msg` and Erlang's `gen_server` have the same shape.

## The rule

- **State changes only in steps.** A ``TurnMachine`` is a value type. Its steps (``TurnMachine/handle(_:_:)``, ``TurnMachine/handleAbandoned(_:_:_:)``, ``TurnMachine/handleLateResult(_:_:)``, ``TurnMachine/answer(_:_:)``) aren't `async`, so a step can't await. Nothing else can change the machine: ``TurnCore`` holds it, and only a step's ``Turn`` reaches the core.
- **Effects come back as inputs.** When a step needs work done, it makes a request (``Turn/request(_:for:holding:)``, ``Turn/request(_:for:deadline:)``) or calls ``Turn/run(_:)``. The adopter's ``TurnActor/perform(_:)`` does the work off the actor. Its result is a new input to a later step, and that step decides what the result means on the state as it is then. A result whose request has closed goes to `handleLateResult`, not to `handle`. A request closes when its key ends or is superseded, its deadline passes, or it is cancelled.
- **What a step can't own, the core owns.** Keys and their generations say which work is still wanted. Holds queue later inputs behind work in flight, with a deadline. Withdraw tokens withdraw an input that was given up before it stepped. The core checks all of them, so a handler holds no tickets.
- **A supersede ends the old generation's queued inputs too.** Calling ``Turn/start(_:)`` on a key that is still live *supersedes* it. That closes the old generation's requests, drops its timer, and withdraws the inputs queued under that key's scope, as ``Turn/end(_:)`` does. A queued input carries no generation, so without this, an input sent under the old binding would step under the new one. Its caller gets ``TurnError/withdrawn`` and can retry. That includes an input sent while a batch runs and admitted after the supersede. Limit: an input that arrives while the key isn't live (before its first `start`, or after an `end`) steps under the next generation; use a fresh key per binding, such as a connection or session id, when that matters.

`@PlainData` checks at compile time that a machine stores only plain values, so a step can't call through anything it holds. Only a `PlainData` machine can be run (``TurnCore/init(_:queueLimit:maxReleasesPerBatch:clock:)``).

## How it's tested

The tests are also examples. Each one below shows a way to check a turn-based actor.

- **Generated orders** (`Tests/SwiftStateTurnsTests/GeneratedOrderTests.swift`). A seeded generator mixes sends, calls, completions, cancellations and clock moves. After every operation, the test checks the core's invariants: no step runs inside another, inputs queued behind one hold step in arrival order, each call is answered once, and only outputs emitted under a live key reach the sink. With the large batch budget, a seed gives the same order run after run; the seeds run with a budget of 2 keep the invariants but not one fixed schedule. A failing seed is printed; adding it to the `replays` test by hand keeps it as a fixed case. CI runs a fixed seed set; `TURNS_SEEDS=<count>` runs more.
- **Code that must not compile** (`scripts/must-not-compile/turns/`, run by `scripts/check-must-not-compile.sh`). Each file must fail to compile with a named error. Together they show what can't be written: a handler that awaits, a handler that starts a task, an effect that reads `core`, a machine that stores a class or a closure (also inside `#if`), and a machine without `@PlainData` given to a core.
- **The worked example** (`Tests/SwiftStateTurnsTests/WorkedExampleTests.swift`). It runs the lobby from these pages. Its last test is the rot check: every Swift block in the DocC and in `docs/turns/` must appear in a tested file, so an example can't drift from the code.
- **The three-version comparison** (`Tests/SwiftStateTurnsTests/ComparisonTests.swift`). A hold inside the profile store's `load` stops a join in the middle of its `await`. The test then sends the leave and releases the load. The order is the same on every run, with no sleeps, so the plain actor's bug happens every time.
- **Runtime stops** (`Tests/SwiftStateTurnsTests/RuntimeStopTests.swift`). A few mistakes can only be caught while running, such as reading the machine from inside its own step. Each one runs in a child process (an exit test), which must stop with the core's message.

## Topics

### Essentials

- <doc:CoreConcepts>
- <doc:WorkedExample>
- <doc:WithoutTheFramework>
- ``TurnMachine``
- ``Turn``
- ``TurnActor``
- ``TurnCore``

### Input policies, work and holds

- ``InputPolicy``
- ``Hold``
- ``RequestID``
- ``Abandonment``
- ``WithdrawToken``
- ``TurnError``
- ``CallerCancellation``

### Time

- ``TurnClock``
- ``TurnInstant``

### Plain data

- ``PlainData``
- ``PlainDataCheck``
- ``PlainPair``

### Observing a core

- ``TurnStats``
- ``TurnDiagnostic``
- ``InputID``
- ``Generation``
