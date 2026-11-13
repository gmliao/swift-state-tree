#!/usr/bin/env python3
"""The wire form a GameServer runs with, from its environment, by the server's own rules
(stdlib only): what a sweep declares, for wireform.check against what its joins observed.

The rules, from the sources:
- `TRANSPORT_ENCODING` picks a preset (Examples/GameDemo/Sources/GameContent/GameHelpers.swift,
  `resolveTransportEncoding`; GameServer's default is "messagepack"): "json" and any unknown
  value give JSON messages with JSON-object state updates; "jsonopcode" (also "json_opcode",
  "json-opcode") JSON messages with opcode state updates; "opcode" opcode-array messages;
  "messagepack" ("msgpack") MessagePack. The joinResponse names the message encoding:
  "json", "opcodeJsonArray" or "messagepack".
- The state-update features exist only with an opcode state-update encoding
  (`TransportEncodingConfig.stateUpdateFeatures`): with JSON-object updates the server echoes
  none, whatever PATH_INDEX and FIELD_MERGE say.
- Without path hashes both are off (`TransportEncodingConfig.effective(pathHashes:)`). The
  hero-defense land passes its schema's path hashes (GameServer main.swift), so they apply.
- Otherwise each is on unless its variable reads as false to the server's `EnvHelpers.getEnvBool`
  (trimmed, case-folded "0", "false", "no", "n" or "off"); any other value keeps the default, on.
- Row addressing (`TransportAdapter`'s rule) takes effect only with opcode state updates, path
  hashes and the path index (`effective(pathHashes:)`; the hosted server has the sync sequence
  and router joins), in-turn sync (`IN_TURN_SYNC` not false) and the delta strategy
  (`SYNC_STRATEGY` unset or "delta"). Requested: `ROW_ADDRESSING` true ("1", "true", "yes", "y",
  "on") or false as the server reads it; unset, its default, off until the commit that made it
  default on (`ROW_DEFAULT_COMMIT`), on from it, judged by the server commit's ancestry.
"""
from __future__ import annotations

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import wireform  # noqa: E402

# TRANSPORT_ENCODING (lowercased) -> (the joinResponse's encoding name, opcode state updates).
PRESETS = {
    "json": ("json", False),
    "jsonopcode": ("json", True), "json_opcode": ("json", True), "json-opcode": ("json", True),
    "opcode": ("opcodeJsonArray", True),
    "messagepack": ("messagepack", True), "msgpack": ("messagepack", True),
}
DEFAULT_ENCODING = "messagepack"
# EnvHelpers.getEnvBool's false and true values (Sources/SwiftStateTree/Support/EnvHelpers.swift).
FALSE_VALUES = {"0", "false", "no", "n", "off"}
TRUE_VALUES = {"1", "true", "yes", "y", "on"}
# The merge commit that made ROW_ADDRESSING default on (#392, PR F); None until it merges: a
# server without the variable set ran with row addressing off.
ROW_DEFAULT_COMMIT: str | None = None


def env_off(value) -> bool:
    """Whether the server reads this variable's value as false."""
    return value is not None and str(value).strip().lower() in FALSE_VALUES


def env_on(value) -> bool:
    """Whether the server reads this variable's value as true."""
    return value is not None and str(value).strip().lower() in TRUE_VALUES


def rows_requested(environ: dict, commit: str | None) -> bool:
    """`ROW_ADDRESSING` as the server reads it: set true or false, or unset, its default at
    `commit` (off before `ROW_DEFAULT_COMMIT`, on from it)."""
    value = environ.get("ROW_ADDRESSING")
    if env_on(value):
        return True
    if env_off(value):
        return False
    if ROW_DEFAULT_COMMIT is None:
        return False
    if not commit:
        raise wireform.MissingWireForm("ROW_ADDRESSING unset and the server commit not recorded: its default changed in "
                                       f"{ROW_DEFAULT_COMMIT}")
    has = wireform.contains(commit, ROW_DEFAULT_COMMIT)
    if has is None:
        raise wireform.MissingWireForm(f"ROW_ADDRESSING unset and commit {commit} is unknown to the repository")
    return has


def intended(environ: dict, path_hashes: bool = True, commit: str | None = None) -> wireform.WireForm:
    """The form a GameServer with this environment sends. `environ` holds TRANSPORT_ENCODING,
    PATH_INDEX, FIELD_MERGE, ROW_ADDRESSING, IN_TURN_SYNC and SYNC_STRATEGY (missing or None: the
    server's default). `commit`: the server's commit, for ROW_ADDRESSING's default."""
    raw = (environ.get("TRANSPORT_ENCODING") or DEFAULT_ENCODING).lower()
    encoding, opcode = PRESETS.get(raw, ("json", False))  # GameServer's fallback is json
    features = opcode and path_hashes
    path_index = features and not env_off(environ.get("PATH_INDEX"))
    delta = (environ.get("SYNC_STRATEGY") or "delta").strip().lower() == "delta"
    rows = (path_index and delta and not env_off(environ.get("IN_TURN_SYNC"))
            and rows_requested(environ, commit))
    return wireform.WireForm(encoding, path_index, features and not env_off(environ.get("FIELD_MERGE")), rows)
