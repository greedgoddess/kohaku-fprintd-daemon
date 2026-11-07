#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Run cros-fprintd on the session bus with a simulated MCU (tests only).

    tests/fake_daemon.py --state-dir /tmp/x [-v]

FAKE_NEVER_MATCH=1 makes every match attempt fail (lockout test);
FAKE_MATCH_INDEX=n reports every attempt as a match for template index n (invalid-index test).
Not installed and not part of the release: the shipped daemon has no test hooks.
"""
import importlib.machinery
import importlib.util
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
_loader = importlib.machinery.SourceFileLoader("cros_fprintd", os.path.join(HERE, "..", "cros-fprintd"))
_spec = importlib.util.spec_from_loader(_loader.name, _loader)
daemon = importlib.util.module_from_spec(_spec)
_loader.exec_module(daemon)

EV_ENROLL, EV_MATCH = daemon.EV_ENROLL, daemon.EV_MATCH
NEVER_MATCH = os.environ.get("FAKE_NEVER_MATCH") == "1"
MATCH_INDEX = os.environ.get("FAKE_MATCH_INDEX")      # always report a match with this index


class FakeMcu:
    """In-memory stand-in for the fingerprint MCU."""

    def __init__(self):
        self.mode = 0
        self.templates = []
        self.dirty = 0
        self.progress = 0
        self.matches = 0
        self.seed_set = False

    def ensure_seed(self, seed, seed_is_new):
        self.seed_set = True

    def set_context(self, userid):
        self.templates, self.dirty, self.progress = [], 0, 0

    def info(self):
        return {"template_size": 64, "max": 5, "valid": len(self.templates), "dirty": self.dirty}

    def load_template(self, blob):
        self.templates.append(blob)

    def read_template(self, index):
        self.dirty = 0
        return (b"FAKE-TEMPLATE-%d-" % index + b"x" * 64)[:64]

    def set_mode(self, mode):
        self.mode = mode

    def drain_events(self):
        pass

    def wait_event(self, timeout):
        time.sleep(min(timeout, 0.15))
        if self.mode & (1 << 5):                       # ENROLL_IMAGE armed
            self.mode &= ~(1 << 5)
            self.progress = min(100, self.progress + 9)
            if self.progress >= 100:
                self.templates.append(b"fake")
                self.mode = 0
                self.progress = 0
                return EV_ENROLL | (100 << 4)
            return EV_ENROLL | (self.progress << 4) | (2 if self.progress % 3 == 0 else 0)
        if self.mode & (1 << 6):                       # MATCH armed
            self.mode &= ~(1 << 6)
            self.matches += 1
            if MATCH_INDEX is not None:
                return EV_MATCH | (int(MATCH_INDEX) << 12) | 1
            if NEVER_MATCH or self.matches % 2 == 1 or not self.templates:
                return EV_MATCH | (0xF << 12)          # no match
            self.dirty = 1
            return EV_MATCH | 3                        # match, template updated, index 0
        return None


daemon.Mcu = lambda path: FakeMcu()
daemon.BUS_TYPE = daemon.Gio.BusType.SESSION

if __name__ == "__main__":
    sys.exit(daemon.main())
