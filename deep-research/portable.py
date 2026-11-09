#!/usr/bin/env python3
"""Paths a committed result may carry: relative to the checkout a sweep ran in, never that
checkout's absolute path on the measurement host.

A sweep's run-time files record paths in that checkout (`GAMESERVER_BIN=<root>/Examples/
GameDemo/.build/release/GameServer`, ws-loadtest's `external server binary <root>/…`). The
sweep's record keeps the root it ran in (runmeta.py: `git.root`, `git rev-parse
--show-toplevel`); a record from before that field takes it from the collector's explicit
`--checkout-root`. `relativize` strips exactly that root, so the host can re-collect from an
existing raw/ and get the same results. Every other absolute path stays as recorded, for the
topics' tests and the commit guard (`absolute_paths`) to catch, never disguised as a
checkout-relative one.
"""
from __future__ import annotations

import re
import sys


def checkout_root(record: dict, override: str | None, where: str) -> str:
    """The checkout root a sweep ran in: its record's `git.root`, else `override`
    (`--checkout-root`); exits when neither is given, they differ, or it isn't absolute."""
    recorded = (record.get("git") or {}).get("root")
    if recorded and override and recorded.rstrip("/") != override.rstrip("/"):
        sys.exit(f"{where}: the record's checkout root {recorded!r} isn't --checkout-root {override!r}")
    root = recorded or override
    if not root:
        sys.exit(f"{where}: the record has no checkout root (git.root); pass --checkout-root <the checkout it ran in>")
    if not root.startswith("/") or root.rstrip("/") == "":
        sys.exit(f"{where}: checkout root {root!r} isn't an absolute directory")
    return root.rstrip("/")


def _pattern(root: str) -> re.Pattern:
    # The root as a whole path at the start of a path: at the start of a line or after a
    # separator, and followed by '/', so /a/sst-W never matches inside /a/sst-Wx or /b/a/sst-W.
    return re.compile(r"(?:(?<=^)|(?<=[\s\"'=(,\[:]))" + re.escape(root) + r"/", re.MULTILINE)


def checkout_relative(text: str, root: str) -> str:
    """`text` with every path under `root` made relative to it; other text unchanged."""
    return _pattern(root.rstrip("/")).sub("", text)


def relativize(value, root: str):
    """`checkout_relative` over every string value of a JSON value (dict keys stay as written)."""
    if isinstance(value, str):
        return checkout_relative(value, root)
    if isinstance(value, dict):
        return {k: relativize(v, root) for k, v in value.items()}
    if isinstance(value, list):
        return [relativize(v, root) for v in value]
    return value


# The host-path guard the data commits run (system directories a checkout or a home lives under).
_ABSOLUTE = re.compile(r"(?:^|[\s\"'=(:,\[])(/(?:home|root|Users|workspace|workspaces|tmp|private|var|opt|mnt|work)/[^\s\"']*)",
                       re.MULTILINE)


def absolute_paths(value) -> list[str]:
    """Every host-style absolute path left in the strings of a JSON value (or a text)."""
    if isinstance(value, str):
        return _ABSOLUTE.findall(value)
    if isinstance(value, dict):
        return [p for k, v in value.items() for p in absolute_paths(k) + absolute_paths(v)]
    if isinstance(value, list):
        return [p for v in value for p in absolute_paths(v)]
    return []
