#!/usr/bin/env bash
# Install (or remove) cros-fprintd on Fedora.
#
#   sudo ./install.sh [SEED_FILE]                 install
#   sudo ./install.sh --uninstall                 stop and remove the service, unmask fprintd
#   sudo ./install.sh --uninstall --purge         ...and delete the seed and enrolled templates
#
# SEED_FILE (optional): the MCU accepts one seed per boot. If something else
# (for example the fpprobe3 tool) already set a seed since the last boot, pass
# the file it used so the daemon uses the same one. Otherwise just reboot first.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN=/usr/local/libexec/cros-fprintd
UNIT=/etc/systemd/system/cros-fprintd.service
DROPIN_DIR=/etc/systemd/system/cros-fprintd.service.d
UDEV_RULE=/etc/udev/rules.d/70-cros-fprintd.rules
STATE=/var/lib/cros-fprintd

if [ "${1:-}" = "--uninstall" ]; then
    systemctl disable --now cros-fprintd.service 2>/dev/null || true
    systemctl unmask fprintd.service 2>/dev/null || true
    rm -f "$BIN" "$UNIT"
    rm -rf "$DROPIN_DIR"
    rm -f "$UDEV_RULE"
    udevadm control --reload-rules 2>/dev/null || true
    systemctl daemon-reload
    if [ "${2:-}" = "--purge" ]; then
        rm -rf "$STATE"
        echo "removed $STATE (seed and enrolled templates)"
    else
        echo "kept $STATE (seed and enrolled templates); use --purge to delete it"
    fi
    echo "Uninstalled. To turn off fingerprint in PAM: sudo authselect disable-feature with-fingerprint"
    exit 0
fi

SEED_SRC="${1:-}"
[ -e /dev/cros_fp ] || { echo "no /dev/cros_fp - is this a Chromebook with a fingerprint MCU (and was the reader alive at boot)?" >&2; exit 1; }
for f in cros-fprintd systemd/cros-fprintd.service systemd/stop-on-suspend.conf udev/70-cros-fprintd.rules; do
    [ -f "$HERE/$f" ] || { echo "missing $HERE/$f" >&2; exit 1; }
done

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
# Stop the daemon before suspend only where suspend means deep sleep (S3), which
# leaves the fingerprint MCU unpowered on Kohaku. With s2idle/S0ix it survives.
if grep -q '\[deep\]' /sys/power/mem_sleep 2>/dev/null; then
    install -D -m 0644 "$HERE/systemd/stop-on-suspend.conf" "$DROPIN_DIR/stop-on-suspend.conf"
    echo "default sleep mode is deep (S3): the daemon will stop itself before suspend"
else
    rm -f "$DROPIN_DIR/stop-on-suspend.conf"
fi
install -D -m 0644 "$HERE/udev/70-cros-fprintd.rules" "$UDEV_RULE"
udevadm control --reload-rules

# The stock fprintd would otherwise be started on demand and compete for the bus name.
systemctl stop fprintd.service 2>/dev/null || true
systemctl mask fprintd.service

systemctl daemon-reload
systemctl enable --now cros-fprintd.service
sleep 1
systemctl --no-pager --full status cros-fprintd.service || {
    echo; echo "service failed to start; see: journalctl -u cros-fprintd -b" >&2; exit 1; }

if ! authselect current 2>/dev/null | grep -q with-fingerprint; then
    cat <<'EOF'

NOTE: fingerprint is not enabled in your PAM configuration yet. Without it,
sudo, the lock screen and polkit won't offer fingerprint, and GNOME keeps
"enable-fingerprint-authentication" switched off. Enable it with
(keep a root shell open the first time you change PAM settings):
    sudo authselect enable-feature with-fingerprint
    sudo authselect apply-changes
EOF
fi

cat <<'EOF'

Installed. Next:
  1. Enroll a finger:  fprintd-enroll
  2. Test it:          fprintd-verify
  3. Log out and back in once, so GNOME Shell picks up the reader.
     Then sudo and the lock screen accept your fingerprint; the password
     always remains as a fallback.

GNOME's login screen (after boot or logout) only offers the password: GNOME
Shell uses fingerprint for re-authentication (the lock screen) only. See README.

Suspend: with s2idle (the default on MrChromebox 2609.3 and later on Kohaku) the
reader keeps working after suspend. With deep sleep (S3) it stops working until a
full power-off, so in that case the daemon stops itself before suspend.
Logs: journalctl -u cros-fprintd -b
EOF
