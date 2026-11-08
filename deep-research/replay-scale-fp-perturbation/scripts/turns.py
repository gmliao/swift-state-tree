#!/usr/bin/env python3
"""Counts a 3.x record's turn records per tick: how many ticks the file splits into several turns.

Usage: turns.py <record.sstr>   prints `<ticks> <turns> <split ticks>`

A 3.x record holds one or more `turn` records per tick, which the reader merges into the tick's
frame. How a tick is split depends on when the recorder flushed (#327), so two recordings of one
input can differ in bytes while their content is the same; run-batch.sh records the split count
next to each file as the reason. The record is decoded with recomputation-cost's standard-library
reader (`regenerate.unpack`), the same one that topic checks against the runtime's JSON view.
"""
import importlib.util
import pathlib
import struct
import sys

_READER = pathlib.Path(__file__).resolve().parents[2] / "recomputation-cost" / "regenerate.py"
_spec = importlib.util.spec_from_file_location("recomputation_cost_regenerate", _READER)
_reader = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_reader)


def turn_counts(data: bytes) -> dict:
    """{tickId: number of turn records}; raises ValueError on a file that isn't a whole 3.x record."""
    if data[:4] != _reader.SSTR_MAGIC:
        raise ValueError("not a 3.x record (no SSTR magic)")
    i, counts, footer = 6, {}, None
    while i < len(data):
        (n,) = struct.unpack_from(">I", data, i)
        record, end = _reader.unpack(data, i + 4)
        if end != i + 4 + n:
            raise ValueError("record length does not match its contents")
        i = end
        if record.get("kind") == "turn":
            counts[record["tickId"]] = counts.get(record["tickId"], 0) + 1
        elif record.get("kind") == "footer":
            footer = record
    if not (footer and footer.get("complete")):
        raise ValueError("record is incomplete (no complete footer)")
    return counts


def summary(data: bytes) -> tuple:
    """(ticks, turns, ticks with more than one turn)."""
    counts = turn_counts(data)
    return len(counts), sum(counts.values()), sum(1 for c in counts.values() if c > 1)


def main(argv):
    if len(argv) != 1:
        sys.exit(__doc__)
    try:
        print(*summary(pathlib.Path(argv[0]).read_bytes()))
    except (OSError, ValueError, IndexError, struct.error) as e:
        sys.exit(f"{argv[0]}: {e}")


if __name__ == "__main__":
    main(sys.argv[1:])
