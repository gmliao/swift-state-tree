#!/usr/bin/env python3
"""gameserver_wire.intended against the server's rules. Run: python3 deep-research/test_gameserver_wire.py"""
import pathlib, sys, unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import gameserver_wire as gw  # noqa: E402

W = gw.wireform.WireForm


class Intended(unittest.TestCase):
    def test_defaults_are_messagepack_with_both_features(self):
        self.assertEqual(gw.intended({}), W("messagepack", True, True))
        self.assertEqual(gw.intended({"TRANSPORT_ENCODING": None, "PATH_INDEX": None}), W("messagepack", True, True))

    def test_json_object_updates_have_no_features_whatever_the_knobs(self):
        self.assertEqual(gw.intended({"TRANSPORT_ENCODING": "json"}), W("json", False, False))
        self.assertEqual(gw.intended({"TRANSPORT_ENCODING": "JSON", "PATH_INDEX": "true"}), W("json", False, False))
        # GameServer falls back to json for an unknown value.
        self.assertEqual(gw.intended({"TRANSPORT_ENCODING": "protobuf"}), W("json", False, False))

    def test_opcode_presets_take_the_knobs(self):
        self.assertEqual(gw.intended({"TRANSPORT_ENCODING": "jsonOpcode"}), W("json", True, True))
        self.assertEqual(gw.intended({"TRANSPORT_ENCODING": "opcode", "FIELD_MERGE": "false"}), W("opcodeJsonArray", True, False))
        self.assertEqual(gw.intended({"TRANSPORT_ENCODING": "msgpack", "PATH_INDEX": "false"}), W("messagepack", False, True))

    def test_without_path_hashes_both_are_off(self):
        self.assertEqual(gw.intended({}, path_hashes=False), W("messagepack", False, False))


if __name__ == "__main__":
    unittest.main()
