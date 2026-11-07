# SPDX-License-Identifier: MIT
"""Deleting fingers while a verify runs: no match for the deleted print, nothing recreated.

Run via tests/run-fake-tests.sh (fake daemon with FAKE_MATCH_INDEX=0, so every attempt
would match, and FAKE_LOAD_DELAY=2, so the deletion lands while the worker is busy).
"""
import glob
import os
import sys
import time

from dbus_helpers import Checks, Client, enroll, wait_for

state = sys.argv[1]
check = Checks()
c = Client()
c.call("Claim", "(s)", ("",))
check(enroll(c), "enrolled a finger")

c.signals.clear()
c.call("VerifyStart", "(s)", ("any",))
time.sleep(0.5)                                   # worker is loading the template
c.call("DeleteEnrolledFingers2")
check(wait_for(lambda: c.status("VerifyStatus"), timeout=20), "verify finished")
res = c.status("VerifyStatus")
check(res and res[0] != ("verify-match", True), f"deleted print does not match (got {res[:1]})")
c.call("VerifyStop")
time.sleep(0.5)                                   # give a (wrong) late save the chance to happen

check(c.error_of("ListEnrolledFingers", "(s)", ("",)) == "net.reactivated.Fprint.Error.NoEnrolledPrints",
      "fingers stay deleted")
leftovers = glob.glob(os.path.join(state, "users", "*", "*.bin"))
check(not leftovers, f"no template files recreated ({leftovers})")
c.call("Release")
sys.exit(check.result())
