#!/usr/bin/env bash
# Run the D-Bus API tests against a simulated MCU on a private session bus.
# No hardware and no root needed.  Usage:  tests/run-fake-tests.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] || [ "${CROS_FPRINTD_TEST_INNER:-}" != 1 ]; then
    exec env CROS_FPRINTD_TEST_INNER=1 dbus-run-session -- "$0" "$@"
fi
STATE="$(mktemp -d)"
LOG="$STATE/daemon.log"
python3 "$HERE/../cros-fprintd" --session-bus --fake-mcu --state-dir "$STATE/state" -v 2> "$LOG" &
DPID=$!
sleep 1.5
python3 "$HERE/test_fake_dbus.py" "$STATE/state"
RC=$?
kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null
echo "---- daemon log ($LOG)"; cat "$LOG"
rm -rf "$STATE"
exit $RC
