#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Install (or remove) cros-fprintd on Fedora.
#
#   sudo ./install.sh [SEED_FILE]              check requirements, then install
#   sudo ./install.sh --check                  only check the requirements
#   sudo ./install.sh --uninstall [--purge]    remove (--purge: also seed + templates)
#
# Supported configuration - anything else is refused:
#   * a ChromeOS fingerprint MCU (/dev/cros_fp); tested on Kohaku only
#   * MrChromebox UEFI firmware 2609.3 or newer
#   * suspend-to-idle with working S0ix; deep sleep (S3) is NOT supported
#
# SEED_FILE (optional): the MCU accepts one seed per boot. If something else
# (e.g. the fpprobe3 tool) set a seed since the last boot, pass the file it used,
# or reboot first.
set -euo pipefail

MIN_FW="2609.3"
R="${FPRINTD_CHECK_ROOT:-}"   # path prefix for testing the checks; empty in real use

[ "$(id -u)" -eq 0 ] || [ -n "$R" ] || exec sudo "$0" "$@"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN=/usr/local/libexec/cros-fprintd
UNIT=/etc/systemd/system/cros-fprintd.service
DROPIN_DIR=/etc/systemd/system/cros-fprintd.service.d
UDEV_RULE=/etc/udev/rules.d/70-cros-fprintd.rules
STATE=/var/lib/cros-fprintd

FAILED=0
ok()  { printf '  [ok]   %s\n' "$*"; }
bad() { printf '  [FAIL] %s\n' "$*"; FAILED=1; }

check_static() {
    echo "Checking requirements:"

    if [ -e "$R/dev/cros_fp" ]; then
        ok "fingerprint MCU present (/dev/cros_fp)"
    else
        bad "no /dev/cros_fp: no ChromeOS fingerprint MCU found, or it is not responding (power off fully and retry)"
    fi

    local ver num
    ver=$(cat "$R/sys/class/dmi/id/bios_version" 2>/dev/null || true)
    case "$ver" in
        MrChromebox-*)
            num=${ver#MrChromebox-}
            if printf '%s\n%s\n' "$MIN_FW" "$num" | sort -V -C; then
                ok "firmware $ver (MrChromebox-$MIN_FW or newer)"
            else
                bad "firmware $ver is older than MrChromebox-$MIN_FW - update it with the MrChromebox Firmware Utility Script"
            fi ;;
        *)  bad "firmware '${ver:-unknown}' is not MrChromebox UEFI firmware" ;;
    esac

    # FADT flags (offset 112), bit 21 = LOW_POWER_S0_IDLE_CAPABLE
    local flags
    flags=$(od -An -t u4 -j 112 -N 4 "$R/sys/firmware/acpi/tables/FACP" 2>/dev/null | tr -d ' ' || true)
    if [ -n "$flags" ] && (( (flags >> 21) & 1 )); then
        ok "firmware advertises S0ix (FADT Low Power S0 Idle)"
    else
        bad "firmware does not advertise S0ix: enable the S0ix option in the firmware setup (press ESC at boot); firmware updates reset it"
    fi

    if ls "$R/sys/bus/acpi/devices/" 2>/dev/null | grep -qiE '^(INT33A1|PNP0D80)'; then
        ok "low-power S0 (LPS0) ACPI device present"
    else
        bad "no low-power S0 (LPS0) ACPI device"
    fi

    if grep -q '\[s2idle\]' "$R/sys/power/mem_sleep" 2>/dev/null; then
        ok "default sleep mode is s2idle"
    else
        bad "default sleep mode is not s2idle ($(cat "$R/sys/power/mem_sleep" 2>/dev/null || echo unknown)); deep sleep (S3) is not supported"
    fi
}

s0ix_residency() {
    [ -n "$R" ] || mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
    cat "$R/sys/kernel/debug/pmc_core/slp_s0_residency_usec" 2>/dev/null || true
}

check_s0ix_works() {
    local before after ans
    before=$(s0ix_residency)
    if [ -z "$before" ]; then
        bad "cannot read the S0ix residency counter (intel_pmc_core debugfs missing)"
        return
    fi
    if [ "$before" -gt 0 ]; then
        ok "S0ix reached since boot ($before us)"
        return
    fi
    echo "  S0ix has not been entered since boot, so it needs a short test: the laptop"
    echo "  suspends for about 20 seconds and wakes up by itself (press a key if not)."
    read -r -p "  Run the suspend test now? [y/N] " ans || ans=""
    case "$ans" in
        [yY]*) ;;
        *) bad "S0ix not verified (test declined)"; return ;;
    esac
    rtcwake -m freeze -s 20 >/dev/null 2>&1 || true
    sleep 2
    after=$(s0ix_residency)
    if [ "${after:-0}" -gt "$before" ]; then
        ok "S0ix works (residency $before -> $after us)"
    else
        bad "S0ix was not reached during the test suspend"
    fi
}

check_all() {
    check_static
    check_s0ix_works
    if [ "$FAILED" -ne 0 ]; then
        echo
        echo "Requirements not met - this configuration is not supported, nothing was installed."
        return 1
    fi
    echo "All requirements met."
}

case "${1:-}" in
    --uninstall)
        systemctl disable --now cros-fprintd.service 2>/dev/null || true
        systemctl unmask fprintd.service 2>/dev/null || true
        rm -f "$BIN" "$UNIT" "$UDEV_RULE"
        rm -rf "$DROPIN_DIR"
        udevadm control --reload-rules 2>/dev/null || true
        systemctl daemon-reload
        if [ "${2:-}" = "--purge" ]; then
            rm -rf "$STATE"
            echo "removed $STATE (seed and enrolled templates)"
        else
            echo "kept $STATE (seed and enrolled templates); use --purge to delete it"
        fi
        echo "Uninstalled. To turn off fingerprint in PAM: sudo authselect disable-feature with-fingerprint"
        exit 0 ;;
    --check)
        if check_all; then exit 0; else exit 1; fi ;;
esac

SEED_SRC="${1:-}"
for f in cros-fprintd systemd/cros-fprintd.service udev/70-cros-fprintd.rules; do
    [ -f "$HERE/$f" ] || { echo "missing $HERE/$f" >&2; exit 1; }
done

check_all
[ -z "$R" ] || { echo "(test mode: stopping before installing)"; exit 0; }

dnf install -y fprintd fprintd-pam python3-gobject

install -d -m 0700 "$STATE"
if [ -n "$SEED_SRC" ]; then
    [ "$(stat -c %s "$SEED_SRC")" -eq 32 ] || { echo "$SEED_SRC must be exactly 32 bytes" >&2; exit 1; }
    if [ -e "$STATE/seed" ] && ! cmp -s "$SEED_SRC" "$STATE/seed"; then
        echo "$STATE/seed already exists and differs from $SEED_SRC - refusing to overwrite." >&2
        exit 1
    fi
    [ -e "$STATE/seed" ] || install -m 0600 "$SEED_SRC" "$STATE/seed"
fi

install -D -m 0755 "$HERE/cros-fprintd" "$BIN"
install -D -m 0644 "$HERE/systemd/cros-fprintd.service" "$UNIT"
install -D -m 0644 "$HERE/udev/70-cros-fprintd.rules" "$UDEV_RULE"
udevadm control --reload-rules
# Older versions stopped the daemon before suspend (for S3); with s2idle it must keep running.
rm -f "$DROPIN_DIR/stop-on-suspend.conf"
rmdir "$DROPIN_DIR" 2>/dev/null || true

# The stock fprintd would otherwise be started on demand and compete for the bus name.
systemctl stop fprintd.service 2>/dev/null || true
systemctl mask fprintd.service

systemctl daemon-reload
systemctl enable cros-fprintd.service
systemctl restart cros-fprintd.service
sleep 1
systemctl --no-pager --full status cros-fprintd.service || {
    echo; echo "service failed to start; see: journalctl -u cros-fprintd -b" >&2; exit 1; }

if ! authselect current 2>/dev/null | grep -q with-fingerprint; then
    cat <<'MSG'

NOTE: fingerprint is not enabled in your PAM configuration yet. Without it,
sudo, the lock screen and polkit won't offer fingerprint, and GNOME keeps
"enable-fingerprint-authentication" switched off. Enable it with
(keep a root shell open the first time you change PAM settings):
    sudo authselect enable-feature with-fingerprint
    sudo authselect apply-changes
MSG
fi

cat <<'MSG'

Installed. Next:
  1. Enroll a finger:  fprintd-enroll
  2. Test it:          fprintd-verify
  3. Log out and back in once, so GNOME Shell picks up the reader.
     Then sudo and the lock screen accept your fingerprint; the password
     always remains as a fallback.

GNOME's login screen (after boot or logout) only offers the password: GNOME
Shell uses fingerprint for re-authentication (the lock screen) only.
Logs: journalctl -u cros-fprintd -b
MSG
