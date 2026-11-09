# SPDX-License-Identifier: MIT
# [doc:tst-match-ordering]
"""A deletion handled between the worker's match and the signal must win.

Drives the daemon's Service directly: a match result is queued, then fingers are
deleted before the main loop sends it - the exact window of the race.
"""
import importlib.machinery
import importlib.util
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
_loader = importlib.machinery.SourceFileLoader("cros_fprintd", os.path.join(HERE, "..", "cros-fprintd"))
_spec = importlib.util.spec_from_loader(_loader.name, _loader)
d = importlib.util.module_from_spec(_spec)
_loader.exec_module(d)
GLib = d.GLib


class Conn:
    def __init__(self):
        self.sent = []

    def emit_signal(self, dest, path, iface, name, params):
        self.sent.append((name, params.unpack()))


def run_main_loop():
    ctx = GLib.MainContext.default()
    while ctx.iteration(False):
        pass


failed = False


def check(cond, msg):
    global failed
    print(("PASS " if cond else "FAIL ") + msg)
    failed |= not cond


with tempfile.TemporaryDirectory() as tmp:
    store = d.Store(os.path.join(tmp, "state"))
    conn = Conn()
    svc = d.Service(conn, None, store)

    gen = store.generation("alice")
    svc._emit_match_result("alice", gen, "right-thumb", True)
    run_main_loop()
    check(conn.sent == [("VerifyStatus", ("verify-match", True))], "match without deletion is reported")

    conn.sent.clear()
    gen = store.generation("alice")
    svc._emit_match_result("alice", gen, "right-thumb", True)   # worker queued the match...
    store.delete_all("alice")                                    # ...deletion runs first
    run_main_loop()
    check(conn.sent == [("VerifyStatus", ("verify-no-match", True))],
          f"deletion before the signal turns the match into no-match ({conn.sent})")
    check(not svc.lockout.locked("alice") and "alice" not in svc.lockout._failures,
          "a match voided by deletion doesn't count as a failed attempt")

print("RESULT:", "FAILED" if failed else "ALL PASSED")
sys.exit(1 if failed else 0)
