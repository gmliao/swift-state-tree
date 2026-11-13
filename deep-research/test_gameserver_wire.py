#!/usr/bin/env python3
"""gameserver_wire.intended against the server's rules. Run: python3 deep-research/test_gameserver_wire.py"""
import pathlib, sys, unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import gameserver_wire as gw  # noqa: E402

W = gw.wireform.WireForm


class Intended(unittest.TestCase):
    """The knobs' rules, with ROW_ADDRESSING's default off (before its flip): RowAddressing below
    covers rows."""

    def setUp(self):
        self.saved, gw.ROW_DEFAULT_COMMIT = gw.ROW_DEFAULT_COMMIT, None

    def tearDown(self):
        gw.ROW_DEFAULT_COMMIT = self.saved

    def test_defaults_are_messagepack_with_both_features(self):
        self.assertEqual(gw.intended({}), W("messagepack", True, True, False))
        self.assertEqual(gw.intended({"TRANSPORT_ENCODING": None, "PATH_INDEX": None}), W("messagepack", True, True, False))

    def test_json_object_updates_have_no_features_whatever_the_knobs(self):
        self.assertEqual(gw.intended({"TRANSPORT_ENCODING": "json"}), W("json", False, False, False))
        self.assertEqual(gw.intended({"TRANSPORT_ENCODING": "JSON", "PATH_INDEX": "true"}), W("json", False, False, False))
        # GameServer falls back to json for an unknown value.
        self.assertEqual(gw.intended({"TRANSPORT_ENCODING": "protobuf"}), W("json", False, False, False))

    def test_opcode_presets_take_the_knobs(self):
        self.assertEqual(gw.intended({"TRANSPORT_ENCODING": "jsonOpcode"}), W("json", True, True, False))
        self.assertEqual(gw.intended({"TRANSPORT_ENCODING": "opcode", "FIELD_MERGE": "false"}), W("opcodeJsonArray", True, False, False))
        self.assertEqual(gw.intended({"TRANSPORT_ENCODING": "msgpack", "PATH_INDEX": "false"}), W("messagepack", False, True, False))

    def test_the_servers_false_values_turn_a_knob_off(self):
        for value in ("0", "off", " OFF ", "no", "n", "False"):
            with self.subTest(value):
                self.assertEqual(gw.intended({"PATH_INDEX": value}), W("messagepack", False, True, False))
        # Anything else keeps the server's default, on.
        for value in ("1", "on", "", "maybe"):
            with self.subTest(value):
                self.assertEqual(gw.intended({"FIELD_MERGE": value}), W("messagepack", True, True, False))

    def test_without_path_hashes_both_are_off(self):
        self.assertEqual(gw.intended({}, path_hashes=False), W("messagepack", False, False, False))


class RowAddressing(unittest.TestCase):
    def setUp(self):
        self.saved = gw.ROW_DEFAULT_COMMIT

    def tearDown(self):
        gw.ROW_DEFAULT_COMMIT = self.saved

    def test_unset_is_off_until_the_default_changes(self):
        gw.ROW_DEFAULT_COMMIT = None
        self.assertFalse(gw.intended({}).row_addressing)
        self.assertFalse(gw.intended({}, commit="6f7920c0").row_addressing)

    def test_set_true_takes_effect_where_its_prerequisites_hold(self):
        self.assertEqual(gw.intended({"ROW_ADDRESSING": "true"}), W("messagepack", True, True, True))
        self.assertEqual(gw.intended({"ROW_ADDRESSING": " ON ", "TRANSPORT_ENCODING": "jsonOpcode"}), W("json", True, True, True))
        # Not without opcode updates, path hashes, the path index, in-turn sync or the delta strategy.
        for env in ({"TRANSPORT_ENCODING": "json"}, {"PATH_INDEX": "false"}, {"IN_TURN_SYNC": "false"},
                    {"SYNC_STRATEGY": "snapshot"}):
            with self.subTest(env):
                self.assertFalse(gw.intended({"ROW_ADDRESSING": "true", **env}).row_addressing)
        self.assertFalse(gw.intended({"ROW_ADDRESSING": "true"}, path_hashes=False).row_addressing)
        # A value the server reads as neither keeps the default.
        gw.ROW_DEFAULT_COMMIT = None
        self.assertFalse(gw.intended({"ROW_ADDRESSING": "maybe"}).row_addressing)

    def test_unset_follows_the_commit_once_the_default_changed(self):
        # Any commit of this repository stands in for the default's merge: its own commit has it,
        # its parent doesn't.
        head = gw.wireform.KNOBS["rowAddressing"]
        gw.ROW_DEFAULT_COMMIT = head
        self.assertTrue(gw.intended({}, commit=head).row_addressing)
        self.assertFalse(gw.intended({}, commit=f"{head}^").row_addressing)
        self.assertFalse(gw.intended({"ROW_ADDRESSING": "false"}, commit=head).row_addressing)
        with self.assertRaisesRegex(gw.wireform.MissingWireForm, "commit not recorded"):
            gw.intended({})
        with self.assertRaisesRegex(gw.wireform.MissingWireForm, "unknown to the repository"):
            gw.intended({}, commit="0123456789abcdef0123456789abcdef01234567")
        # A squashed branch commit resolves through its squash merge, as wireform's knobs do.
        self.assertFalse(gw.intended({}, commit="b8e798b").row_addressing)


if __name__ == "__main__":
    unittest.main()
