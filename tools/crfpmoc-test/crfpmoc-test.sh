#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Test libfprint's proposed crfpmoc driver (merge request !512) on this laptop without
# installing anything system-wide: the stock fprintd binary runs by hand against a
# locally built libfprint. cros-fprintd is held back during the test and restored after.
#
#   crfpmoc-test.sh build     fetch the merge request and build libfprint
#   crfpmoc-test.sh patch     apply the FP_MODE reply-size fix locally, then rebuild
#   crfpmoc-test.sh hold      keep cros-fprintd from starting (then reboot)
#   crfpmoc-test.sh run       run the test fprintd (Ctrl+C to stop); logs to ~/src/crfpmoc-test
#   crfpmoc-test.sh state     chip state, stored prints, SELinux denials
#   crfpmoc-test.sh restore   let cros-fprintd start again (then reboot)
set -euo pipefail

DIR="$HOME/src/crfpmoc-test"
SRC="$DIR/libfprint"
LIB="$SRC/build/libfprint"
MON=/usr/local/libexec/cros-fprintd-monitor
PROBE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../fpprobe/fpprobe7"
BOOT_ID="$(cat /proc/sys/kernel/random/boot_id)"
# cros-fprintd's unit is a file in /etc, so it can't be masked; a drop-in with an
# impossible condition keeps it from starting instead (also when udev asks for it).
# [doc:crf-hold]
HOLD=/etc/systemd/system/cros-fprintd.service.d/zz-crfpmoc-test.conf

chip_seed() {      # prints 1 if the chip already has a seed this boot, 0 if not, ? if unknown
    if [ -x "$MON" ]; then
        sudo "$MON" status 2>/dev/null | grep -o 'seed=[01]' | cut -d= -f2 || echo "?"
    else
        echo "?"
    fi
}

case "${1:-}" in
# [doc:crf-build]
build)
    sudo dnf install -y git meson ninja-build gcc
    sudo dnf builddep -y libfprint
    mkdir -p "$DIR"
    [ -d "$SRC" ] || git clone https://gitlab.freedesktop.org/libfprint/libfprint.git "$SRC"
    cd "$SRC"
    git fetch origin merge-requests/512/head
    git checkout -q --detach FETCH_HEAD
    git log -1 --format='testing merge request !512 at %h (%cd): %s' --date=short | tee "$DIR/VERSION"
    rm -rf build
    # crfpmoc alone fails ("crfpmoc requires udev"): libfprint only enables udev support when a
    # driver it lists as needing udev is built. elanspi is one; it finds nothing on a Chromebook.
    meson setup build -Ddrivers=crfpmoc,elanspi -Ddoc=false -Dgtk-examples=false
    ninja -C build
    ls -l "$LIB"/libfprint-2.so*
    [ -x "$PROBE" ] || make -C "$(dirname "$PROBE")" >/dev/null
    echo "Built. Next: $0 hold, reboot, then: $0 run"
    ;;

# [doc:crf-patch]
patch)
    # FP_MODE always returns 4 bytes on this firmware; calls that expect 0 fail with EMSGSIZE.
    [ -d "$SRC" ] || { echo "run '$0 build' first" >&2; exit 1; }
    python3 - "$SRC/libfprint/drivers/crfpmoc/crfpmoc.c" <<'PY'
import re, sys
p = sys.argv[1]
lines = open(p).read().split("\n")
for i, line in enumerate(lines):
    if "CRFPMOC_EC_CMD_FP_MODE, 0," not in line:
        continue
    for j in range(i, i + 4):
        if ");" in lines[j]:
            if re.search(r",\s*0\);", lines[j]):
                lines[j] = re.sub(r",\s*0\);", ", sizeof (struct crfpmoc_ec_response_fp_mode));", lines[j])
                print(f"fixed line {j + 1}")
            break
open(p, "w").write("\n".join(lines))
PY
    ninja -C "$SRC/build" | tail -1
    ;;

hold)
    printf '[Unit]\n# crfpmoc test: keeps cros-fprintd from starting; removed by crfpmoc-test.sh restore\nConditionPathExists=/nonexistent/crfpmoc-test\n' \
        | { sudo mkdir -p "$(dirname "$HOLD")" && sudo tee "$HOLD" >/dev/null; }
    sudo systemctl daemon-reload
    sudo systemctl stop cros-fprintd 2>/dev/null || true
    echo "cros-fprintd is held back. Reboot now, then: $0 run"
    ;;

# [doc:crf-run]
run)
    [ -e "$LIB/libfprint-2.so.2" ] || { echo "run '$0 build' first" >&2; exit 1; }
    if [ ! -e "$HOLD" ]; then
        echo "cros-fprintd isn't held back. Run '$0 hold', reboot, then run this again." >&2
        exit 1
    fi
    if systemctl is-active --quiet cros-fprintd; then
        echo "cros-fprintd is still running. Reboot first (it won't start again)." >&2
        exit 1
    fi
    seed="$(chip_seed)"
    first_run_this_boot=yes
    [ "$(cat "$DIR/.boot" 2>/dev/null)" = "$BOOT_ID" ] && first_run_this_boot=no
    if [ "$seed" = 1 ] && [ "$first_run_this_boot" = yes ]; then
        echo "The chip already has a seed from another program this boot (probably cros-fprintd)." >&2
        echo "crfpmoc can't set its own. Reboot (cros-fprintd stays masked) and run this again." >&2
        exit 1
    fi
    echo "$BOOT_ID" > "$DIR/.boot"
    log="$DIR/fprintd-$(date +%Y%m%d-%H%M%S).log"
    echo "chip seed before start: $seed | logging to $log | Ctrl+C stops"
    sudo env LD_LIBRARY_PATH="$LIB" G_MESSAGES_DEBUG=all /usr/libexec/fprintd --no-timeout 2>&1 | tee "$log"
    ;;

state)
    echo "--- chip (cros-fprintd shows as not running during the test; that's expected)"
    if [ -x "$MON" ]; then sudo "$MON" status; else echo "monitor not installed"; fi
    echo "--- template state on the chip"
    if [ -x "$PROBE" ]; then sudo "$PROBE" | grep -iE 'templ|dirty|valid' || true; else echo "fpprobe7 not built"; fi
    echo "--- prints stored by fprintd"
    sudo find /var/lib/fprint -type f -printf '%TY-%Tm-%Td %TH:%TM  %8s bytes  %p\n' 2>/dev/null | sort || echo "none"
    echo "--- SELinux denials this boot"
    sudo ausearch -m avc -ts boot 2>/dev/null | grep -iE 'fprint|cros_fp' | tail -5 || echo "none"
    ;;

restore)
    sudo rm -f "$HOLD"
    sudo rmdir /etc/systemd/system/cros-fprintd.service.d 2>/dev/null || true
    sudo systemctl daemon-reload
    echo "cros-fprintd can start again. Reboot now; afterwards fprintd-verify uses cros-fprintd again."
    echo "Prints stored by the test stay in /var/lib/fprint; remove them with: sudo rm -rf /var/lib/fprint"
    ;;

*)
    sed -n '3,12p' "$0"
    exit 2
    ;;
esac
