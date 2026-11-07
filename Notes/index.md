# Notes Index

Design and development notes. They record how the project got here; the code and `docs/` are the source of truth, and some notes are out of date (marked where known). Most design notes are in Traditional Chinese.

| Folder | What it holds |
|---|---|
| [design/](design/) | Early design documents (state tree, sync policies, reevaluation, multi-room) |
| [guides/](guides/) | Development guides: debugging, JWT, crash triage |
| [plans/](plans/README.md) | Design and implementation plans, with a status index (done / partial / superseded / open) |
| [solutions/](solutions/README.md) | Reusable lessons from solved problems (bug classes, traps, measurement pitfalls), with an index. Search it before designing a fix |
| [performance/](performance/) | Historical benchmark notes (January 2026); current measurements live in `../deep-research/` |
| [protocol/](protocol/) | Wire protocol and opcode notes |
| [matchmaking/](matchmaking/README.md) | Archived: the Swift matchmaking module moved to `Archive/`; matchmaking now lives in `Packages/control-plane` |

Experiment data, with one README per experiment and a `regenerate.py` that rebuilds its tables, lives in [`../deep-research/`](../deep-research/README.md).
