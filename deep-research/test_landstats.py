"""landstats.py: the per-bin medians over lands, the flows, and the stationarity rule."""
import json
import pathlib
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import landstats  # noqa: E402

T0 = 1_000_000


def lines(monsters, seconds=60, lands=3):
    """One line per second from T0: ``monsters(t, land)`` live; 6 spawned, 4 killed, 2 at the base per s."""
    return [{"fromTs": T0 + t * 1000 - 1000, "ts": T0 + t * 1000, "writeFailures": 0,
             "lands": {f"l{i}": {"tick": t * 20, "monsters": monsters(t, i), "baseHealth": max(0, 100 - 2 * t),
                                 "players": 5, "spawned": 6 * t, "killed": 4 * t, "reachedBase": 2 * t}
                       for i in range(lands)}}
            for t in range(seconds)]


class Summary(unittest.TestCase):
    def test_bins_take_the_median_over_lands_and_the_flows_per_land_per_second(self):
        s = landstats.summary(lines(lambda t, i: 10 * (i + 1)), T0, T0 + 60_000)
        self.assertEqual([b["s"] for b in s["bins"]], [0, 10, 20, 30, 40, 50])
        self.assertEqual({b["median"] for b in s["bins"]}, {20})
        self.assertEqual((s["bins"][0]["p10"], s["bins"][0]["p90"]), (10, 30))
        self.assertEqual(s["bins"][0]["rates"], {"spawned": 6.0, "killed": 4.0, "reachedBase": 2.0})
        self.assertEqual(s["bins"][0]["baseHealth"], 91)  # t 0-9: 100 .. 82, the median of every line
        self.assertEqual((s["cov"], s["maxDev"], s["drift"]), (0, 0, 0))
        self.assertTrue(landstats.stationary(s))

    def test_the_window_bounds_the_lines_and_an_empty_window_is_none(self):
        s = landstats.summary(lines(lambda t, i: t), T0 + 20_000, T0 + 40_000)
        self.assertEqual([b["s"] for b in s["bins"]], [0, 10])
        self.assertEqual([b["median"] for b in s["bins"]], [24.5, 34.5])
        self.assertIsNone(landstats.summary(lines(lambda t, i: 5), T0 + 100_000, T0 + 200_000))
        self.assertFalse(landstats.stationary(None))

    def test_the_rule_bounds_the_spread_and_each_bin(self):
        # A rise of 2 per bin (30 -> 40, a third over the window) is within the CoV and bin bounds
        # (CoV 0.098, the outer bins 14 % off the mean) but drifts 23 %: the drift bound refuses it.
        slow = landstats.summary(lines(lambda t, i: 30 + t // 10 * 2), T0, T0 + 60_000)
        self.assertEqual((slow["cov"], slow["maxDev"], slow["drift"]), (0.0976, 0.1429, 0.2286))
        self.assertLessEqual(slow["cov"], landstats.COV_BOUND)
        self.assertFalse(landstats.stationary(slow))
        # So does a fall, and a faster rise (30 -> 45) fails the CoV too.
        falling = landstats.summary(lines(lambda t, i: 40 - t // 10 * 2), T0, T0 + 60_000)
        self.assertEqual(falling["drift"], -0.2286)
        self.assertFalse(landstats.stationary(falling))
        fast = landstats.summary(lines(lambda t, i: 30 + t // 10 * 3), T0, T0 + 60_000)
        self.assertEqual(fast["cov"], 0.1366)
        self.assertFalse(landstats.stationary(fast))
        # Within the bound: half a monster per bin (30 -> 32.5, a twelfth over the window) drifts 6 %,
        # and bin-to-bin noise without a trend drifts least.
        creep = landstats.summary(lines(lambda t, i: 30 + t // 10 * 0.5), T0, T0 + 60_000)
        self.assertEqual(creep["drift"], 0.064)
        self.assertTrue(landstats.stationary(creep))
        noise = landstats.summary(lines(lambda t, i: (31, 29, 30, 31, 29, 30)[t // 10]), T0, T0 + 60_000)
        self.assertEqual(noise["drift"], -0.0167)
        self.assertTrue(landstats.stationary(noise))
        # One bin 50 % up: over MAX_DEV, whatever the CoV.
        spike = landstats.summary(lines(lambda t, i: 45 if 20 <= t < 30 else 30), T0, T0 + 60_000)
        self.assertGreater(spike["maxDev"], landstats.MAX_DEV)
        self.assertFalse(landstats.stationary(spike))
        # The ramped #425 diagnostic's medians (2 -> 30 over the measured segments): far over the CoV bound.
        diag = [2, 2, 2, 2, 3, 3, 3, 4, 5, 5, 7, 10, 14, 27, 30, 30, 30, 30]
        ramped = landstats.summary(lines(lambda t, i: diag[t // 10], seconds=180), T0, T0 + 180_000)
        self.assertGreater(ramped["cov"], 0.9)
        self.assertFalse(landstats.stationary(ramped))

    def test_the_drift_takes_a_third_of_the_bins_and_at_least_one(self):
        # 18 bins (network-impairment's 180 s): the first and last 6; 2 bins: one each.
        long = landstats.summary(lines(lambda t, i: 30 if t < 120 else 33, seconds=180), T0, T0 + 180_000)
        self.assertEqual(long["drift"], round(3 / 31, 4))
        two = landstats.summary(lines(lambda t, i: 30 if t < 10 else 36, seconds=20), T0, T0 + 20_000)
        self.assertEqual(two["drift"], round(6 / 33, 4))
        one = landstats.summary(lines(lambda t, i: 30, seconds=10), T0, T0 + 10_000)
        self.assertEqual(one["drift"], 0)

    def test_read_skips_blank_lines(self):
        d = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, d)
        (d / "land-stats.jsonl").write_text("\n".join(json.dumps(l) for l in lines(lambda t, i: 1, seconds=3)) + "\n\n")
        self.assertEqual(len(landstats.read(d / "land-stats.jsonl")), 3)


if __name__ == "__main__":
    unittest.main()
