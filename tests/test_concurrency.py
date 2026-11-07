# SPDX-License-Identifier: MIT
"""A released session must keep the device busy until its worker has really ended.

Run via tests/run-fake-tests.sh (fake daemon with FAKE_LOAD_DELAY=3, so a verify
worker spends about 3 s loading templates).
"""
import sys
import time

from dbus_helpers import Checks, Client, enroll, wait_for

check = Checks()
a, b = Client(), Client()

a.call("Claim", "(s)", ("",))
check(enroll(a), "client A enrolled a finger")
a.call("VerifyStart", "(s)", ("any",))       # worker now busy loading for ~3 s
time.sleep(0.3)
a.call("Release")                              # worker is still running

err = b.error_of("Claim", "(s)", ("",))
check(err == "net.reactivated.Fprint.Error.AlreadyInUse",
      f"B cannot claim while A's released worker still runs (got {err})")

claimed = wait_for(lambda: b.error_of("Claim", "(s)", ("",)) is None, timeout=15)
check(claimed, "B can claim once A's worker has finished")
started = claimed and b.error_of("VerifyStart", "(s)", ("any",)) is None
check(started, "B can start once A's worker has finished")
if started:
    check(wait_for(lambda: b.status("VerifyStatus")), "B's verify completes")
    b.call("VerifyStop")
b.call("Release")
sys.exit(check.result())
