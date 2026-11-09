# SPDX-License-Identifier: MIT
# [doc:tst-helpers]
"""Small shared helpers for the D-Bus tests (session bus, signals, checks)."""
import os
import time

import gi

gi.require_version("Gio", "2.0")
gi.require_version("GLib", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

NAME, DEV, DI = "net.reactivated.Fprint", "/net/reactivated/Fprint/Device/0", "net.reactivated.Fprint.Device"


class Client:
    """One D-Bus connection to the daemon, collecting its device signals."""

    def __init__(self):
        self.conn = Gio.DBusConnection.new_for_address_sync(
            os.environ["DBUS_SESSION_BUS_ADDRESS"],
            Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
            None, None)
        self.signals = []
        self.conn.signal_subscribe(NAME, DI, None, DEV, None, Gio.DBusSignalFlags.NONE,
                                   lambda c, s, p, i, sig, params: self.signals.append((sig, params.unpack())))

    def call(self, method, fmt=None, args=(), reply=None):
        p = GLib.Variant(fmt, args) if fmt else None
        rt = GLib.VariantType(reply) if reply else None
        r = self.conn.call_sync(NAME, DEV, DI, method, p, rt, Gio.DBusCallFlags.NONE, 10000, None)
        return r.unpack() if r is not None else None

    def error_of(self, method, fmt=None, args=()):
        try:
            self.call(method, fmt, args)
            return None
        except GLib.Error as e:
            return Gio.DBusError.get_remote_error(e)

    def status(self, kind):
        return [s[1] for s in self.signals if s[0] == kind]

    def close(self):
        self.conn.close_sync(None)


def wait_for(pred, timeout=15):
    ctx, t0 = GLib.MainContext.default(), time.time()
    while time.time() - t0 < timeout:
        while ctx.iteration(False):
            pass
        if pred():
            return True
        time.sleep(0.02)
    return False


class Checks:
    def __init__(self):
        self.failed = False

    def __call__(self, cond, msg):
        print(("PASS " if cond else "FAIL ") + msg)
        self.failed |= not cond

    def result(self):
        print("RESULT:", "FAILED" if self.failed else "ALL PASSED")
        return 1 if self.failed else 0


def enroll(client, finger="right-index-finger"):
    client.signals.clear()
    client.call("EnrollStart", "(s)", (finger,))
    ok = wait_for(lambda: any(s[1] for s in client.status("EnrollStatus")))
    client.call("EnrollStop")
    return ok and client.status("EnrollStatus")[-1] == ("enroll-completed", True)
