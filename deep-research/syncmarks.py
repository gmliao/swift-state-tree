"""Full-view starts and partial outputs in a re-evaluation record's sync stream (stdlib only).

A 3.x record (`.sstr`, `ReevaluationRecordLog`) is a 6-byte preamble (`SSTR`, major, minor) and
records, each a 4-byte big-endian length and one MessagePack map with a `kind`: a `header`, `turn`
records, a `footer`. A turn record's `syncOutputs` and `syncMarkers` together are the sync stream,
ordered by `streamIndex`.

What the stream records, and what `count` counts:
- A full view sent to a player is a `seed` marker: its first view (firstSync), or a rejoin
  (`rejoin`). A resync in place (#332) is a `clear` marker, then a `seed`, for the same player.
  `count` splits the seeds into each player's first one and the later ones, and the later ones
  into rejoins, seeds right after a clear for that player, and others.
- An output with `resetsKeyScopes` typed every recipient's update `.firstSync` to reset the
  dynamic key tables: a diff, not a full view. Counted apart (`key_scope_resets`).
- Partial outputs: an output without `broadcastHash` (the broadcast scope wasn't committed), with
  `perPlayerUncommitted` (per-player updates planned but not sent), `perPlayerUnverified`,
  `encodeDropScopes`, `extractionDrops` or `eventsNotMerged`; a seed with `viewDrops` (its view
  isn't verifiable). These are what the runner's sync-output check reports as skipped or
  unverifiable.
- A sync phase that planned nothing (skipped: no members or a frozen land; deferred: back-pressure)
  writes nothing to the stream, so no record says it happened.

`verify_line` reads the same counts that a runner's "Sync Output:" line gives for a record that
isn't kept: seeds (every column), skipped, unverifiable, and the key scope resets of its suffix.
"""
import re
import struct

PREAMBLE = b"SSTR"
PARTIAL = ("broadcast_not_committed", "per_player_uncommitted", "per_player_unverified",
           "encode_drops", "extraction_drops", "events_not_merged", "seed_view_drops")


def unpack(data, i=0):
    """(value, next offset) of the MessagePack value at `i`; ValueError on an ext type or a bad byte."""
    b = data[i]
    i += 1
    if b <= 0x7F:
        return b, i
    if b >= 0xE0:
        return b - 0x100, i
    if 0x80 <= b <= 0x8F:
        return _map(data, i, b & 0x0F)
    if 0x90 <= b <= 0x9F:
        return _array(data, i, b & 0x0F)
    if 0xA0 <= b <= 0xBF:
        n = b & 0x1F
        return data[i:i + n].decode("utf-8"), i + n
    fixed = {0xC0: None, 0xC2: False, 0xC3: True}
    if b in fixed:
        return fixed[b], i
    sized = {0xCC: ">B", 0xCD: ">H", 0xCE: ">I", 0xCF: ">Q", 0xD0: ">b", 0xD1: ">h", 0xD2: ">i", 0xD3: ">q",
             0xCA: ">f", 0xCB: ">d"}
    if b in sized:
        fmt = sized[b]
        return struct.unpack_from(fmt, data, i)[0], i + struct.calcsize(fmt)
    lengths = {0xD9: (">B", "str"), 0xDA: (">H", "str"), 0xDB: (">I", "str"),
               0xC4: (">B", "bin"), 0xC5: (">H", "bin"), 0xC6: (">I", "bin"),
               0xDC: (">H", "array"), 0xDD: (">I", "array"), 0xDE: (">H", "map"), 0xDF: (">I", "map")}
    if b not in lengths:
        raise ValueError(f"MessagePack byte 0x{b:02x} at {i - 1} is not supported")
    fmt, what = lengths[b]
    n = struct.unpack_from(fmt, data, i)[0]
    i += struct.calcsize(fmt)
    if what == "str":
        return data[i:i + n].decode("utf-8"), i + n
    if what == "bin":
        return bytes(data[i:i + n]), i + n
    return (_array if what == "array" else _map)(data, i, n)


def _array(data, i, n):
    out = []
    for _ in range(n):
        v, i = unpack(data, i)
        out.append(v)
    return out, i


def _map(data, i, n):
    out = {}
    for _ in range(n):
        k, i = unpack(data, i)
        v, i = unpack(data, i)
        out[k] = v
    return out, i


def read_log(data):
    """The records of a 3.x record file, in file order; ValueError unless it is one, complete."""
    if data[:4] != PREAMBLE:
        raise ValueError("not a 3.x record (no SSTR preamble)")
    i, records = 6, []
    while i < len(data):
        if i + 4 > len(data):
            raise ValueError(f"cut length at {i}")
        (n,) = struct.unpack_from(">I", data, i)
        body = data[i + 4:i + 4 + n]
        if len(body) != n:
            raise ValueError(f"cut record at {i}")
        value, end = unpack(body)
        if end != n or not isinstance(value, dict):
            raise ValueError(f"record at {i} is not one map")
        records.append(value)
        i += 4 + n
    kinds = [r.get("kind") for r in records]
    if not kinds or kinds[0] != "header" or kinds[-1] != "footer" or set(kinds[1:-1]) - {"turn"}:
        raise ValueError(f"records are not header, turns, footer: {kinds[:1]}...{kinds[-1:]}")
    if records[-1].get("complete") is not True:
        raise ValueError("the footer doesn't mark the record complete")
    return records


def stream(records):
    """[(kind, entry)] of the sync stream, kind "output" or "marker", ordered by streamIndex;
    ValueError unless the indices are exactly 0..n-1."""
    entries = []
    for r in records:
        if r.get("kind") != "turn":
            continue
        entries += [("output", o) for o in r.get("syncOutputs") or []]
        entries += [("marker", m) for m in r.get("syncMarkers") or []]
    entries.sort(key=lambda e: e[1]["streamIndex"])
    if [e[1]["streamIndex"] for e in entries] != list(range(len(entries))):
        raise ValueError("stream indices are not 0..n-1")
    return entries


def count(data):
    """The sync stream's counts for one record file (see the module docstring)."""
    records = read_log(data)
    footer = records[-1]
    entries = stream(records)
    if footer.get("syncStreamCount") is not None and footer["syncStreamCount"] != len(entries):
        raise ValueError(f"footer counts {footer['syncStreamCount']} stream entries, the turns hold {len(entries)}")
    seeded, last = set(), {}
    c = {"format": records[0].get("format"), "outputs": 0, "markers": {"seed": 0, "clear": 0, "initialize": 0},
         "players": 0, "seeds_first": 0, "seeds_later": 0, "seeds_later_rejoin": 0, "seeds_later_after_clear": 0,
         "seeds_later_other": 0, "key_scope_resets": 0, "partial": {k: 0 for k in PARTIAL}}
    p = c["partial"]
    for kind, e in entries:
        if kind == "output":
            c["outputs"] += 1
            c["key_scope_resets"] += e.get("resetsKeyScopes") is True
            p["broadcast_not_committed"] += "broadcastHash" not in e
            p["per_player_uncommitted"] += bool(e.get("perPlayerUncommitted"))
            p["per_player_unverified"] += bool(e.get("perPlayerUnverified"))
            p["encode_drops"] += bool(e.get("encodeDropScopes"))
            p["extraction_drops"] += any(e.get("extractionDrops", {}).values())
            p["events_not_merged"] += e.get("eventsNotMerged") is not None
            continue
        k = e["kind"]
        if k not in c["markers"]:
            raise ValueError(f"unknown marker kind {k!r}")
        c["markers"][k] += 1
        player = e.get("playerID")
        if k == "seed":
            p["seed_view_drops"] += bool(e.get("viewDrops"))
            if player not in seeded:
                seeded.add(player)
                c["seeds_first"] += 1
            else:
                c["seeds_later"] += 1
                if e.get("rejoin") is True:
                    c["seeds_later_rejoin"] += 1
                elif last.get(player) == "clear":
                    c["seeds_later_after_clear"] += 1
                else:
                    c["seeds_later_other"] += 1
        if player is not None:
            last[player] = k
    c["players"] = len(seeded)
    return c


LINE = re.compile(r"^\s*Sync Output: \w+ \[compared/unverifiable/skipped: ([^\]]*)\](?:; (\d+) key scope resets)?", re.M)
PART = re.compile(r"([\w-]+) (\d+)/(\d+)/(\d+)")


def verify_line(text):
    """{"seeds", "unverifiable", "skipped", "key_scope_resets", "scopes"} from one runner output's
    "Sync Output:" line; ValueError unless it has exactly one with counts. seeds sums the seed
    scope's three columns; unverifiable and skipped sum every scope's; scopes holds each scope's
    {"compared", "unverifiable", "skipped"}."""
    found = LINE.findall(text)
    if len(found) != 1:
        raise ValueError(f"{len(found)} 'Sync Output:' lines with counts, expected 1")
    parts, resets = found[0]
    out = {"seeds": None, "unverifiable": 0, "skipped": 0, "key_scope_resets": int(resets or 0), "scopes": {}}
    for kind, compared, unverifiable, skipped in PART.findall(parts):
        if kind in out["scopes"]:
            raise ValueError(f"scope {kind} twice in the line")
        out["scopes"][kind] = {"compared": int(compared), "unverifiable": int(unverifiable), "skipped": int(skipped)}
        out["unverifiable"] += int(unverifiable)
        out["skipped"] += int(skipped)
        if kind == "seed":
            out["seeds"] = int(compared) + int(unverifiable) + int(skipped)
    if out["seeds"] is None:
        raise ValueError("no seed scope in the line")
    return out
