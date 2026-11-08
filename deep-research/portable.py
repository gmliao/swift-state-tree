#!/usr/bin/env python3
"""Paths a committed result may carry: relative to the checkout root, never the measurement
host's absolute checkout path.

A sweep's run-time files record the paths it ran with (`GAMESERVER_BIN=/…/Examples/GameDemo/
.build/release/GameServer`, ws-loadtest's `external server binary /…`), in whichever checkout
it ran. A collector passes every string it writes into results/ through `checkout_relative`,
which cuts each absolute path that runs into one of the repository's top-level directories
down to the part from that directory (`Examples/GameDemo/.build/release/GameServer`), so the
host can re-collect from an existing raw/ and the results are the same wherever they were
collected. `absolute_paths` finds what is left, for the topics' tests.
"""
from __future__ import annotations

import re

# The repository's top-level directories a recorded path can run into.
TOP_LEVEL = ("Examples", "Sources", "Tests", "Tools", "deep-research", "sdk", "docs", "Notes", "scripts")
_CHECKOUT = re.compile(r"(?:(?<=^)|(?<=[\s\"'=(,\[]))/(?!/)[^\s\"']*?/(?=(?:" + "|".join(map(re.escape, TOP_LEVEL)) + r")/)",
                       re.MULTILINE)
# The host-path guard the data commits run (system directories a checkout or a home lives under).
_ABSOLUTE = re.compile(r"(?:^|[\s\"'=(:,\[])(/(?:home|root|Users|workspace|workspaces|tmp|private|var|opt|mnt|work)/[^\s\"']*)",
                       re.MULTILINE)


def checkout_relative(text: str) -> str:
    """`text` with every absolute path into the checkout's top-level directories made relative to the checkout."""
    return _CHECKOUT.sub("", text)


def relativize(value):
    """`checkout_relative` over every string of a JSON value (keys included)."""
    if isinstance(value, str):
        return checkout_relative(value)
    if isinstance(value, dict):
        return {relativize(k): relativize(v) for k, v in value.items()}
    if isinstance(value, list):
        return [relativize(v) for v in value]
    return value


def absolute_paths(value) -> list[str]:
    """Every host-style absolute path left in the strings of a JSON value (or a text)."""
    if isinstance(value, str):
        return _ABSOLUTE.findall(value)
    if isinstance(value, dict):
        return [p for k, v in value.items() for p in absolute_paths(k) + absolute_paths(v)]
    if isinstance(value, list):
        return [p for v in value for p in absolute_paths(v)]
    return []
