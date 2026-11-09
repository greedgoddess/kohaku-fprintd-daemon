# SPDX-License-Identifier: MIT
# [doc:tst-lockout]
"""Lockout test: after 5 failed matches VerifyStart is refused.

Run via tests/run-fake-tests.sh (needs the fake daemon with FAKE_NEVER_MATCH=1).
"""
import os
import sys
import time

import gi

gi.require_version("Gio", "2.0")
gi.require_version("GLib", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

NAME, DEV, DI = "net.reactivated.Fprint", "/net/reactivated/Fprint/Device/0", "net.reactivated.Fprint.Device"
c = Gio.DBusConnection.new_for_address_sync(
    os.environ["DBUS_SESSION_BUS_ADDRESS"],
    Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
    None, None)
signals = []
c.signal_subscribe(NAME, DI, None, DEV, None, Gio.DBusSignalFlags.NONE,
                   lambda conn, snd, path, iface, sig, params: signals.append((sig, params.unpack())))


def dev(method, fmt=None, args=()):
    p = GLib.Variant(fmt, args) if fmt else None
    return c.call_sync(NAME, DEV, DI, method, p, None, Gio.DBusCallFlags.NONE, 10000, None)


def wait_for(pred, timeout=15):
    ctx, t0 = GLib.MainContext.default(), time.time()
    while time.time() - t0 < timeout:
        while ctx.iteration(False):
            pass
        if pred():
            return True
        time.sleep(0.02)
    return False


failed = False


def check(cond, msg):
    global failed
    print(("PASS " if cond else "FAIL ") + msg)
    failed |= not cond


dev("Claim", "(s)", ("",))
dev("EnrollStart", "(s)", ("right-index-finger",))
check(wait_for(lambda: any(s[0] == "EnrollStatus" and s[1][1] for s in signals)), "enrolled a finger")
dev("EnrollStop")

for i in range(5):
    signals.clear()
    dev("VerifyStart", "(s)", ("any",))
    got = wait_for(lambda: any(s[0] == "VerifyStatus" for s in signals))
    res = [s[1] for s in signals if s[0] == "VerifyStatus"]
    check(got and res[0] == ("verify-no-match", True), f"attempt {i + 1}: no match")
    dev("VerifyStop")

try:
    dev("VerifyStart", "(s)", ("any",))
    check(False, "6th VerifyStart refused after 5 failed matches")
except GLib.Error as e:
    check(Gio.DBusError.get_remote_error(e) == "net.reactivated.Fprint.Error.Internal",
          "6th VerifyStart refused after 5 failed matches")
dev("Release")
print("RESULT:", "FAILED" if failed else "ALL PASSED")
sys.exit(1 if failed else 0)
