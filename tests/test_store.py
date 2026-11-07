# SPDX-License-Identifier: MIT
"""Unit tests for the daemon's storage: private files, size limits, deletion races."""
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

failed = False


def check(cond, msg):
    global failed
    print(("PASS " if cond else "FAIL ") + msg)
    failed |= not cond


def raises(exc, fn):
    try:
        fn()
    except exc:
        return True
    return False


with tempfile.TemporaryDirectory() as tmp:
    root = os.path.join(tmp, "state")
    store = d.Store(root)
    check(len(store.seed) == 32 and store.seed_is_new, "new 32-byte seed created")
    check(os.stat(os.path.join(root, "seed")).st_mode & 0o777 == 0o600, "seed file is 0600")
    check(d.Store(root).seed == store.seed, "seed is reloaded unchanged")

    users = os.path.join(root, "users")
    gen = store.generation("alice")
    check(store.save("alice", gen, templates={"right-thumb": b"x" * 64}, order=["right-thumb"]),
          "save succeeds with the current generation")
    check(store.fingers("alice") == ["right-thumb"], "saved finger is listed")
    leftovers = [n for n in os.listdir(os.path.join(users, "alice")) if n.startswith(".tmp-")]
    check(not leftovers, "no temporary files left behind")

    store.delete_all("alice")
    check(not store.save("alice", gen, templates={"right-thumb": b"y" * 64}),
          "late save after deletion is refused (no resurrected prints)")
    check(store.fingers("alice") == [] and not os.path.exists(os.path.join(users, "alice", "right-thumb.bin")),
          "deleted prints stay deleted")

    big = os.path.join(users, "alice", "left-thumb.bin")
    with open(big, "wb") as f:
        f.write(b"z" * (d.MAX_TEMPLATE_BYTES + 1))
    os.chmod(big, 0o600)
    check(raises(ValueError, lambda: store.read_finger("alice", "left-thumb")), "oversized template refused")

    seed = os.path.join(root, "seed")
    os.chmod(seed, 0o644)
    check(raises(PermissionError, lambda: d.Store(root)), "seed readable by others is refused")
    os.chmod(seed, 0o600)

    os.rename(seed, seed + ".real")
    os.symlink(seed + ".real", seed)
    check(raises(OSError, lambda: d.Store(root)), "seed that is a symlink is refused")
    os.unlink(seed)
    os.rename(seed + ".real", seed)

    os.chmod(root, 0o755)
    os.chmod(users, 0o755)
    d.Store(root)
    check(os.stat(root).st_mode & 0o777 == 0o700 and os.stat(users).st_mode & 0o777 == 0o700,
          "too-open state directories are tightened to 0700")

    os.rename(users, users + ".real")
    os.symlink(users + ".real", users)
    check(raises(PermissionError, lambda: d.Store(root)), "users directory that is a symlink is refused")

print("RESULT:", "FAILED" if failed else "ALL PASSED")
sys.exit(1 if failed else 0)
