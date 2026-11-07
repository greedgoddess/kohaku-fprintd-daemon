#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Run all tests: storage unit tests, D-Bus tests against a simulated MCU on a private
# session bus, and installer tests in a temporary directory. No hardware and no root needed.  Usage:  tests/run-fake-tests.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${CROS_FPRINTD_TEST_INNER:-}" != 1 ]; then
    exec env CROS_FPRINTD_TEST_INNER=1 dbus-run-session -- "$0" "$@"
fi

TMP="$(mktemp -d)"
LOG="$TMP/daemon.log"
DPID=""
RC=0
cleanup() {
    if [ -n "$DPID" ]; then kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null; fi
    rm -rf "$TMP"
}
trap cleanup EXIT

start_daemon() {            # start_daemon <state dir> [VAR=value ...]
    local state=$1; shift
    env "$@" python3 "$HERE/fake_daemon.py" --state-dir "$state" -v 2>>"$LOG" &
    DPID=$!
    for _ in $(seq 100); do
        if gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
               --method org.freedesktop.DBus.NameHasOwner net.reactivated.Fprint 2>/dev/null \
               | grep -q true; then
            return 0
        fi
        kill -0 "$DPID" 2>/dev/null || break
        sleep 0.1
    done
    echo "FAIL daemon did not come up"
    return 1
}

stop_daemon() {
    if [ -n "$DPID" ]; then kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null; DPID=""; fi
}

run_suite() {               # run_suite <title> <state dir> <test script> [VAR=value ...]
    local title=$1 state=$2 script=$3; shift 3
    echo "---- $title"
    if start_daemon "$state" "$@"; then
        python3 "$HERE/$script" "$state" || RC=1
    else
        RC=1
    fi
    stop_daemon
}

echo "---- storage"
python3 "$HERE/test_store.py" || RC=1
run_suite "D-Bus API"      "$TMP/s1" test_fake_dbus.py
run_suite "lockout"        "$TMP/s2" test_lockout.py FAKE_NEVER_MATCH=1
run_suite "lockout reset and expiry" "$TMP/s7" test_lockout_reset.py \
    FAKE_MATCH_PATTERN=nnnnynnnnnn FAKE_LOCKOUT_SECONDS=3
run_suite "invalid index"  "$TMP/s3" test_bad_index.py FAKE_MATCH_INDEX=9
run_suite "worker lifetime" "$TMP/s5" test_concurrency.py FAKE_LOAD_DELAY=3
run_suite "delete during verify" "$TMP/s6" test_delete_race.py FAKE_MATCH_INDEX=0 FAKE_LOAD_DELAY=2

echo "---- installer"
bash "$HERE/test_installer.sh" || RC=1

echo "---- unsafe seed file"
mkdir -m 0700 "$TMP/s4" && head -c 32 /dev/urandom > "$TMP/s4/seed" && chmod 0644 "$TMP/s4/seed"
if timeout 10 python3 "$HERE/fake_daemon.py" --state-dir "$TMP/s4" 2>"$TMP/s4.log"; then
    echo "FAIL daemon started with a world-readable seed"; RC=1
elif grep -q "accessible to other users" "$TMP/s4.log"; then
    echo "PASS daemon refuses a world-readable seed"
else
    echo "FAIL unexpected failure:"; cat "$TMP/s4.log"; RC=1
fi

echo
if [ "$RC" -eq 0 ]; then
    echo "ALL TEST SUITES PASSED"
else
    echo "SOME TESTS FAILED - daemon log:"; cat "$LOG"
fi
exit "$RC"
