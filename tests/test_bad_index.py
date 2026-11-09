# SPDX-License-Identifier: MIT
# [doc:tst-bad-index]
"""A match report with a template index the daemon never loaded must not count as a match.

Run via tests/run-fake-tests.sh (fake daemon with FAKE_MATCH_INDEX=9).
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


dev("Claim", "(s)", ("",))
dev("EnrollStart", "(s)", ("right-index-finger",))
enrolled = wait_for(lambda: any(s[0] == "EnrollStatus" and s[1][1] for s in signals))
dev("EnrollStop")
signals.clear()
dev("VerifyStart", "(s)", ("any",))
wait_for(lambda: any(s[0] == "VerifyStatus" for s in signals))
res = [s[1] for s in signals if s[0] == "VerifyStatus"]
dev("VerifyStop")
dev("Release")
ok = enrolled and res and res[0] == ("verify-unknown-error", True)
print(("PASS" if ok else "FAIL") + f" match for invalid index 9 is rejected (got {res})")
print("RESULT:", "ALL PASSED" if ok else "FAILED")
sys.exit(0 if ok else 1)
