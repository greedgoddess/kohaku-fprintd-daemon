#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Install (or remove) cros-fprintd on Fedora.
#
#   sudo ./install.sh                          check requirements, then install
#   sudo ./install.sh --check                  only check the requirements
#   sudo ./install.sh --uninstall [--purge]    remove (--purge: also seed + templates)
#
# Supported configuration - anything else is refused:
#   * a ChromeOS fingerprint MCU (/dev/cros_fp); tested on Kohaku only
#   * MrChromebox UEFI firmware 2609.3 or newer
#   * suspend-to-idle with working S0ix; deep sleep (S3) is NOT supported
#
# The MCU accepts one encryption seed per boot. If a development tool (fpprobe3)
# has set one since the last boot, reboot before installing.
set -euo pipefail

MIN_FW="2609.3"
R="${FPRINTD_CHECK_ROOT:-}"   # path prefix for testing the checks; empty in real use
D="${FPRINTD_DESTDIR:-}"      # path prefix for testing install/uninstall; empty in real use

[ "$(id -u)" -eq 0 ] || [ -n "$R" ] || [ -n "$D" ] || exec sudo "$0" "$@"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN=$D/usr/local/libexec/cros-fprintd
UNIT=$D/etc/systemd/system/cros-fprintd.service
DROPIN_DIR=$D/etc/systemd/system/cros-fprintd.service.d
UDEV_RULE=$D/etc/udev/rules.d/70-cros-fprintd.rules
STATE=$D/var/lib/cros-fprintd
OWNER=()
[ "$(id -u)" -ne 0 ] || OWNER=(-o root -g root)

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

# Connected USB readers that the stock fprintd (libfprint) supports. Masking fprintd
# makes them stop working, so the installer asks first. Prints "vendor:product driver".
libfprint_readers() {
    local hwdb="$R/usr/lib/udev/hwdb.d/60-autosuspend-libfprint-2.hwdb" d
    [ -r "$hwdb" ] || return 0
    local supported
    supported="$(awk '/^# Supported by libfprint driver/ { drv = $NF; on = 1; next }
                      /^# Known unsupported devices/      { on = 0 }
                      on && /^usb:v....p..../ { print tolower(substr($0, 6, 4)) ":" tolower(substr($0, 11, 4)) " " drv }' "$hwdb")"
    [ -n "$supported" ] || return 0
    for d in "$R"/sys/bus/usb/devices/*; do
        [ -r "$d/idVendor" ] && [ -r "$d/idProduct" ] || continue
        printf '%s\n' "$supported" | grep -i "^$(cat "$d/idVendor"):$(cat "$d/idProduct") " || true
    done | sort -u
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
    local readers
    readers="$(libfprint_readers)"
    if [ -n "$readers" ]; then
        echo "  [note] connected reader supported by the stock fprintd, which stops working while"
        echo "         cros-fprintd is installed: $(echo "$readers" | tr '\n' ' ')"
    fi
}

# The stock fprintd's state before the first install, so uninstalling can put it back
# exactly (an administrator may have masked or enabled it on purpose).
FPRINTD_STATE_FILE=$STATE/installer-fprintd-state

# States of fprintd.service that can be restored exactly. Others (linked, alias,
# generated, transient, ...) are refused before anything is changed.
fprintd_state_supported() {
    case "$1" in
        static|indirect|disabled|enabled|enabled-runtime|masked|masked-runtime) return 0 ;;
        *) return 1 ;;
    esac
}

BOOT_ID="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)"

restore_fprintd() {      # restore_fprintd <is-enabled state> <is-active state> [boot id of the record]
    [ "$1" = masked ] && return 0                     # was masked before: keep it masked
    systemctl unmask fprintd.service 2>/dev/null || true
    # runtime states end with the boot they were set in; after a reboot they're already gone
    if [ "${1%-runtime}" != "$1" ] && [ "${3:-$BOOT_ID}" != "$BOOT_ID" ]; then return 0; fi
    case "$1" in
        enabled)         systemctl enable fprintd.service 2>/dev/null || true ;;
        enabled-runtime) systemctl enable --runtime fprintd.service 2>/dev/null || true ;;
        masked-runtime)  systemctl mask --runtime fprintd.service 2>/dev/null || true; return 0 ;;
    esac
    if [ "$2" = active ]; then systemctl start fprintd.service 2>/dev/null || true; fi
}

case "${1:-}" in
    --uninstall)
        systemctl disable --now cros-fprintd.service 2>/dev/null || true
        if [ -r "$FPRINTD_STATE_FILE" ]; then
            read -r prev_enabled prev_active prev_boot < "$FPRINTD_STATE_FILE" || true
            restore_fprintd "${prev_enabled:-unknown}" "${prev_active:-inactive}" "${prev_boot:-unknown}"
            echo "restored the stock fprintd service to its previous state (${prev_enabled:-unknown})"
            rm -f "$FPRINTD_STATE_FILE"
        else
            systemctl unmask fprintd.service 2>/dev/null || true
            echo "unmasked the stock fprintd service (its state before installation wasn't recorded)"
        fi
        rm -f "$BIN" "$UNIT" "$UDEV_RULE" "$DROPIN_DIR/stop-on-suspend.conf"
        if rmdir "$DROPIN_DIR" 2>/dev/null || [ ! -d "$DROPIN_DIR" ]; then :; else
            echo "left $DROPIN_DIR in place: it contains drop-ins this installer didn't create"
        fi
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

[ -z "${1:-}" ] || { echo "unknown option: $1 (use --check or --uninstall)" >&2; exit 2; }
for f in cros-fprintd systemd/cros-fprintd.service udev/70-cros-fprintd.rules; do
    [ -f "$HERE/$f" ] || { echo "missing $HERE/$f" >&2; exit 1; }
done

check_all
[ -z "$R" ] || [ -n "$D" ] || { echo "(test mode: stopping before installing)"; exit 0; }

dnf install -y fprintd fprintd-pam python3-gobject

READERS="$(libfprint_readers)"
if [ -n "$READERS" ]; then
    echo
    echo "A fingerprint reader supported by the stock fprintd is connected:"
    printf '%s\n' "$READERS" | sed 's/^/    /'
    echo "cros-fprintd replaces the stock fprintd service (it gets masked), so this reader"
    echo "won't work while cros-fprintd is installed. Uninstalling restores it."
    read -r -p "Install anyway? [y/N] " ans || ans=""
    case "$ans" in
        [yY]*) ;;
        *) echo "Nothing was changed."; exit 1 ;;
    esac
fi

# --- install, with rollback to the previous state if any step fails -----------
PREV_ENABLED="$(systemctl is-enabled fprintd.service 2>/dev/null || true)"
PREV_ACTIVE="$(systemctl is-active fprintd.service 2>/dev/null || true)"
UPGRADE=no
[ -e "$UNIT" ] && UPGRADE=yes
if [ "$UPGRADE" = no ] && ! fprintd_state_supported "$PREV_ENABLED"; then
    echo "fprintd.service is in state '${PREV_ENABLED:-unknown}', which this installer can't restore" >&2
    echo "exactly after uninstalling. Return it to a standard state first (for example" >&2
    echo "'sudo systemctl reenable fprintd.service' or 'sudo systemctl unmask fprintd.service')." >&2
    echo "Nothing was changed." >&2
    exit 1
fi
STATE_FILE_EXISTED=no
[ -e "$FPRINTD_STATE_FILE" ] && STATE_FILE_EXISTED=yes
BACKUP="$(mktemp -d)"
WAS_ACTIVE=no
systemctl is-active --quiet cros-fprintd.service && WAS_ACTIVE=yes
for f in "$BIN" "$UNIT" "$UDEV_RULE" "$DROPIN_DIR/stop-on-suspend.conf"; do
    if [ -e "$f" ]; then cp -a "$f" "$BACKUP/$(basename "$f")"; fi
done

rollback() {
    trap - ERR
    echo >&2
    echo "Installation failed - restoring the previous state." >&2
    for f in "$BIN" "$UNIT" "$UDEV_RULE" "$DROPIN_DIR/stop-on-suspend.conf"; do
        if [ -e "$BACKUP/$(basename "$f")" ]; then
            install -d "$(dirname "$f")"
            cp -a "$BACKUP/$(basename "$f")" "$f"
        else
            rm -f "$f"
        fi
    done
    restore_fprintd "${PREV_ENABLED:-unknown}" "${PREV_ACTIVE:-inactive}"
    [ "$STATE_FILE_EXISTED" = yes ] || rm -f "$FPRINTD_STATE_FILE"
    udevadm control --reload-rules 2>/dev/null || true
    systemctl daemon-reload
    if [ "$WAS_ACTIVE" = yes ]; then
        systemctl restart cros-fprintd.service 2>/dev/null || true
    else
        systemctl disable --now cros-fprintd.service 2>/dev/null || true
    fi
    rm -rf "$BACKUP"
    echo "See: journalctl -u cros-fprintd -b" >&2
    exit 1
}
set -E
trap rollback ERR

install -D "${OWNER[@]}" -m 0755 "$HERE/cros-fprintd" "$BIN"
install -D "${OWNER[@]}" -m 0644 "$HERE/systemd/cros-fprintd.service" "$UNIT"
install -D "${OWNER[@]}" -m 0644 "$HERE/udev/70-cros-fprintd.rules" "$UDEV_RULE"
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
sleep 2
if ! systemctl is-active --quiet cros-fprintd.service; then
    systemctl --no-pager --full status cros-fprintd.service >&2 || true
    rollback
fi
# Record the original fprintd state while rollback is still armed: if this fails,
# the installation is undone instead of losing the information.
if [ "$STATE_FILE_EXISTED" = no ]; then
    install -d -m 0700 "$STATE"
    if [ "$UPGRADE" = yes ]; then record="unknown inactive $BOOT_ID"
    else record="${PREV_ENABLED:-unknown} ${PREV_ACTIVE:-inactive} $BOOT_ID"; fi
    ( umask 077; printf '%s\n' "$record" > "$FPRINTD_STATE_FILE.tmp" )
    mv -f "$FPRINTD_STATE_FILE.tmp" "$FPRINTD_STATE_FILE"
fi
trap - ERR
rm -rf "$BACKUP"
systemctl --no-pager --full status cros-fprintd.service || true

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
