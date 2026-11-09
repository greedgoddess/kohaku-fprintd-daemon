# SPDX-License-Identifier: MIT
# [doc:tst-api]
"""D-Bus API test for cros-fprintd against its simulated MCU.

Run via tests/run-fake-tests.sh; the argument is the daemon's state directory.
"""
import os, sys, stat, time
import gi
gi.require_version("Gio", "2.0"); gi.require_version("GLib", "2.0")
from gi.repository import Gio, GLib

STATE = sys.argv[1]
NAME, DEV = "net.reactivated.Fprint", "/net/reactivated/Fprint/Device/0"
DI, MI = "net.reactivated.Fprint.Device", "net.reactivated.Fprint.Manager"

def connect():
    return Gio.DBusConnection.new_for_address_sync(
        os.environ["DBUS_SESSION_BUS_ADDRESS"],
        Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
        None, None)

c = connect()
signals = []
c.signal_subscribe(NAME, DI, None, DEV, None, Gio.DBusSignalFlags.NONE,
                   lambda conn, snd, path, iface, sig, params: signals.append((sig, params.unpack())))

def call(conn, path, iface, method, fmt=None, args=(), reply="()"):
    p = GLib.Variant(fmt, args) if fmt else None
    return conn.call_sync(NAME, path, iface, method, p, GLib.VariantType(reply),
                          Gio.DBusCallFlags.NONE, 10000, None).unpack()

def dev(method, fmt=None, args=(), reply="()", conn=None):
    return call(conn or c, DEV, DI, method, fmt, args, reply)

def err_of(fn):
    try:
        fn(); return None
    except GLib.Error as e:
        return Gio.DBusError.get_remote_error(e)

def wait_for(pred, timeout=15):
    ctx = GLib.MainContext.default(); t0 = time.time()
    while time.time() - t0 < timeout:
        while ctx.iteration(False): pass
        if pred(): return True
        time.sleep(0.02)
    return False

def check(cond, msg):
    print(("PASS " if cond else "FAIL ") + msg)
    if not cond: check.failed = True
check.failed = False

print("default device:", call(c, "/net/reactivated/Fprint/Manager", MI, "GetDefaultDevice", reply="(o)"))
check(call(c, "/net/reactivated/Fprint/Manager", MI, "GetDevices", reply="(ao)")[0] == [DEV], "GetDevices lists the device")

props = c.call_sync(NAME, DEV, "org.freedesktop.DBus.Properties", "GetAll", GLib.Variant("(s)", (DI,)),
                    GLib.VariantType("(a{sv})"), Gio.DBusCallFlags.NONE, 5000, None).unpack()[0]
check(props["scan-type"] == "press" and props["num-enroll-stages"] == 12, f"properties: {props}")

check(err_of(lambda: dev("ListEnrolledFingers", "(s)", ("",), "(as)")) == "net.reactivated.Fprint.Error.NoEnrolledPrints",
      "ListEnrolledFingers with nothing enrolled -> NoEnrolledPrints")
check(err_of(lambda: dev("VerifyStart", "(s)", ("any",))) == "net.reactivated.Fprint.Error.ClaimDevice",
      "VerifyStart without Claim -> ClaimDevice")

# --- enroll (as GNOME Settings / fprintd-enroll would)
dev("Claim", "(s)", ("",))
c2 = connect()
check(err_of(lambda: dev("Claim", "(s)", ("",), conn=c2)) == "net.reactivated.Fprint.Error.AlreadyInUse",
      "second Claim from another client -> AlreadyInUse")
check(err_of(lambda: dev("EnrollStart", "(s)", ("bogus-finger",))) == "net.reactivated.Fprint.Error.InvalidFingername",
      "invalid finger name rejected")
dev("EnrollStart", "(s)", ("right-index-finger",))
check(wait_for(lambda: any(s[0] == "EnrollStatus" and s[1][1] for s in signals)), "enrollment finished")
st = [s[1][0] for s in signals if s[0] == "EnrollStatus"]
print("enroll statuses:", st)
check(st[-1] == "enroll-completed" and st.count("enroll-stage-passed") >= 10, "enroll: stages then enroll-completed")
check(err_of(lambda: dev("EnrollStart", "(s)", ("left-thumb",))) == "net.reactivated.Fprint.Error.AlreadyInUse",
      "EnrollStart while previous session not stopped -> AlreadyInUse")
dev("EnrollStop"); dev("Release")
check(dev("ListEnrolledFingers", "(s)", ("",), "(as)")[0] == ["right-index-finger"], "finger listed after enroll")

# --- verify (as pam_fprintd would: retry after no-match)
signals.clear()
dev("Claim", "(s)", ("",))
dev("VerifyStart", "(s)", ("any",))
check(wait_for(lambda: any(s[0] == "VerifyStatus" for s in signals)), "got first verify result")
first = [s for s in signals if s[0] == "VerifyStatus"][0][1]
check(first == ("verify-no-match", True), f"first attempt -> {first}")
dev("VerifyStop")
signals.clear()
dev("VerifyStart", "(s)", ("any",))
check(wait_for(lambda: any(s[0] == "VerifyStatus" for s in signals)), "got second verify result")
second = [s for s in signals if s[0] == "VerifyStatus"][0][1]
check(second == ("verify-match", True), f"second attempt -> {second}")
check(any(s[0] == "VerifyFingerSelected" for s in signals), "VerifyFingerSelected emitted")
dev("VerifyStop")
check(err_of(lambda: dev("VerifyStop")) == "net.reactivated.Fprint.Error.NoActionInProgress", "VerifyStop twice -> NoActionInProgress")

# --- client vanishing releases the claim
dev("Release")
dev("Claim", "(s)", ("",), conn=c2)
c2.close_sync(None)
check(wait_for(lambda: err_of(lambda: dev("Claim", "(s)", ("",))) is None, 5), "claim released when client disconnects")
dev("Release")

# --- storage checks
import pwd
user = pwd.getpwuid(os.getuid()).pw_name
base = os.path.join(STATE, "users", user)
mode = lambda p: stat.S_IMODE(os.stat(p).st_mode)
check(mode(os.path.join(STATE, "seed")) == 0o600, "seed file mode 0600")
check(mode(os.path.join(base, "right-index-finger.bin")) == 0o600, "template file mode 0600")
check(mode(STATE) == 0o700, "state dir mode 0700")
blob = open(os.path.join(base, "right-index-finger.bin"), "rb").read()
check(blob.startswith(b"FAKE-TEMPLATE-0-"), "template file written from MCU read-out")

dev("DeleteEnrolledFingers", "(s)", ("",))
check(err_of(lambda: dev("ListEnrolledFingers", "(s)", ("",), "(as)")) == "net.reactivated.Fprint.Error.NoEnrolledPrints",
      "delete removes enrolled fingers")
print("RESULT:", "FAILED" if check.failed else "ALL PASSED")
sys.exit(1 if check.failed else 0)
