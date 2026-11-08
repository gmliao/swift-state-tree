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
- Otherwise each is on unless its variable is "false" (both default to on).
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


def intended(environ: dict, path_hashes: bool = True) -> wireform.WireForm:
    """The form a GameServer with this environment sends. `environ` holds TRANSPORT_ENCODING,
    PATH_INDEX and FIELD_MERGE (missing or None: the server's default)."""
    raw = (environ.get("TRANSPORT_ENCODING") or DEFAULT_ENCODING).lower()
    encoding, opcode = PRESETS.get(raw, ("json", False))  # GameServer's fallback is json
    features = opcode and path_hashes
    return wireform.WireForm(encoding, features and environ.get("PATH_INDEX") != "false",
                             features and environ.get("FIELD_MERGE") != "false")
