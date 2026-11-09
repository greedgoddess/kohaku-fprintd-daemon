# SPDX-License-Identifier: MIT
# [doc:tst-lockout-reset]
"""Lockout details: a successful match resets the count, and the lockout expires.

Run via tests/run-fake-tests.sh with FAKE_MATCH_PATTERN=nnnnynnnnnn (4 failures, a match,
then failures) and FAKE_LOCKOUT_SECONDS=3.
"""
import sys
import time

from dbus_helpers import Checks, Client, enroll, wait_for

ERR_INTERNAL = "net.reactivated.Fprint.Error.Internal"
check = Checks()
c = Client()
c.call("Claim", "(s)", ("",))
check(enroll(c), "enrolled a finger")


def attempt():
    """One verify attempt: the VerifyStatus result, or the error name if refused."""
    c.signals.clear()
    err = c.error_of("VerifyStart", "(s)", ("any",))
    if err:
        return err
    wait_for(lambda: c.status("VerifyStatus"))
    c.call("VerifyStop")
    res = c.status("VerifyStatus")
    return res[0][0] if res else "no result"


results = [attempt() for _ in range(5)]
check(results == ["verify-no-match"] * 4 + ["verify-match"], f"4 failures, then a match ({results})")

results = [attempt() for _ in range(4)]
check(results == ["verify-no-match"] * 4,
      "4 more failures are still allowed: the match reset the count")
check(attempt() == "verify-no-match", "5th consecutive failure is still evaluated")
check(attempt() == ERR_INTERNAL, "then VerifyStart is refused (locked)")

time.sleep(3.5)
check(attempt() == "verify-no-match", "after the lockout expires, verification works again")
c.call("Release")
sys.exit(check.result())
