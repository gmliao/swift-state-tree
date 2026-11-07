#!/usr/bin/env python3
"""Tests for projhash.py. Usage: python3 test_projhash.py"""
import json, pathlib, subprocess, sys, tempfile, unittest

TOPIC = pathlib.Path(__file__).resolve().parent


def capture(root, fmt, projections):
    run = root / f"{fmt}-delta-r1-p5-m4-active-serial"
    run.mkdir(parents=True)
    lines = [json.dumps({"format": fmt})] + [json.dumps({"sync": i, "frames": [{"to": "*", "data": fmt}], "projections": p})
                                              for i, p in enumerate(projections)]
    (run / "room-0.ndjson").write_text("\n".join(lines) + "\n")


def hashes(root):
    out = root / "out.json"
    subprocess.run([sys.executable, str(TOPIC / "projhash.py"), str(root), str(out)], check=True)
    return json.loads(out.read_text())


class ProjHash(unittest.TestCase):
    def test_same_projections_hash_the_same_whatever_the_frames_and_key_order(self):
        a, b = pathlib.Path(tempfile.mkdtemp()), pathlib.Path(tempfile.mkdtemp())
        capture(a, "messagepack-pathhash", [{"p": {"x": 1, "y": 2}}, {"p": {"x": 2, "y": 2}}])
        capture(b, "entity-delta", [{"p": {"y": 2, "x": 1}}, {"p": {"y": 2, "x": 2}}])
        ha, hb = hashes(a), hashes(b)
        self.assertEqual(list(ha), ["r1-p5-m4-active-serial"])
        self.assertEqual(len(ha["r1-p5-m4-active-serial"]["room-0.ndjson"]), 2)
        self.assertEqual(ha, hb)

    def test_a_changed_value_changes_its_sync_only(self):
        a, b = pathlib.Path(tempfile.mkdtemp()), pathlib.Path(tempfile.mkdtemp())
        capture(a, "x", [{"p": {"x": 1}}, {"p": {"x": 2}}])
        capture(b, "x", [{"p": {"x": 1}}, {"p": {"x": 3}}])
        ra, rb = hashes(a)["r1-p5-m4-active-serial"]["room-0.ndjson"], hashes(b)["r1-p5-m4-active-serial"]["room-0.ndjson"]
        self.assertEqual(ra[0], rb[0])
        self.assertNotEqual(ra[1], rb[1])


if __name__ == "__main__":
    unittest.main()
