"""python3 -m unittest server.test_muse_probe - stdlib only."""
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
import muse_probe


def payload(used=25.0, resets_at=1791400000):
    return {"subs_usage": {"window": {"used_percent": used, "resets_at": resets_at}},
            "user_email": "ada@example.com"}


class CacheLogic(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cache = os.path.join(self.tmp.name, "subs.json")
        self.fail = os.path.join(self.tmp.name, "fail")
        self.p1 = mock.patch.object(muse_probe, "CACHE_PATH", self.cache)
        self.p2 = mock.patch.object(muse_probe, "FAIL_PATH", self.fail)
        self.p1.start()
        self.p2.start()

    def tearDown(self):
        self.p1.stop()
        self.p2.stop()
        self.tmp.cleanup()

    def run_main(self):
        buf = io.StringIO()
        with redirect_stdout(buf):
            muse_probe.main()
        return json.loads(buf.getvalue())

    def test_fresh_cache_serves_without_token_or_net(self):
        muse_probe.save_cache(payload())
        with mock.patch.object(muse_probe, "read_token",
                               side_effect=AssertionError("no keychain")), \
             mock.patch.object(muse_probe, "fetch_subs",
                               side_effect=AssertionError("no net")):
            out = self.run_main()
        self.assertEqual(out["quotas"][0]["percentRemaining"], 75.0)
        self.assertEqual(out["email"], "ada@example.com")

    def test_failure_marks_quiet_and_serves_stale(self):
        with open(self.cache, "w") as f:  # cache vecchia di un giorno
            json.dump({"at": 1.0, "payload": payload()}, f)
        with mock.patch.object(muse_probe, "read_token", return_value=None):
            out = self.run_main()
        self.assertEqual(out["quotas"][0]["percentRemaining"], 75.0)
        self.assertTrue(os.path.exists(self.fail))
        # secondo giro: non ritenta nemmeno il token (silenzio 15 min)
        with mock.patch.object(muse_probe, "read_token",
                               side_effect=AssertionError("retry!")):
            out2 = self.run_main()
        self.assertEqual(out2["quotas"][0]["percentRemaining"], 75.0)

    def test_success_clears_fail_flag(self):
        with open(self.fail, "w") as f:
            f.write("1.0")  # fallimento di ieri: scaduto, si riprova
        with mock.patch.object(muse_probe, "read_token", return_value="tok"), \
             mock.patch.object(muse_probe, "fetch_subs",
                               return_value=payload(used=10.0)):
            out = self.run_main()
        self.assertEqual(out["quotas"][0]["percentRemaining"], 90.0)
        self.assertFalse(os.path.exists(self.fail))

    def test_total_failure_prints_empty_quotas(self):
        with mock.patch.object(muse_probe, "read_token", return_value=None):
            out = self.run_main()
        self.assertEqual(out, {"quotas": [], "email": None})


if __name__ == "__main__":
    unittest.main()
