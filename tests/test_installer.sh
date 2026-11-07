#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Installer/uninstaller safety tests. Runs entirely inside a temporary directory:
# FPRINTD_CHECK_ROOT points the requirement checks at a fake /sys, FPRINTD_DESTDIR
# prefixes every installed path, and systemctl/udevadm/dnf are stubs. No root needed.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$HERE/../install.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
FAILED=0
check() { if eval "$1"; then echo "PASS $2"; else echo "FAIL $2"; FAILED=1; fi; }

# --- fake system: supported configuration
fake_sys() {      # fake_sys <mem_sleep line>
    rm -rf "$T/sys"; mkdir -p "$T/sys/dev" "$T/sys/sys/class/dmi/id" "$T/sys/sys/firmware/acpi/tables" \
        "$T/sys/sys/power" "$T/sys/sys/bus/acpi/devices/INT33A1:00" "$T/sys/sys/kernel/debug/pmc_core"
    touch "$T/sys/dev/cros_fp"
    echo MrChromebox-2609.3 > "$T/sys/sys/class/dmi/id/bios_version"
    python3 -c "import struct; b=bytearray(276); struct.pack_into('<I', b, 112, 1 << 21); open('$T/sys/sys/firmware/acpi/tables/FACP','wb').write(b)"
    echo "$1" > "$T/sys/sys/power/mem_sleep"
    echo 123456 > "$T/sys/sys/kernel/debug/pmc_core/slp_s0_residency_usec"
}

# --- stubs
mkdir -p "$T/bin" "$T/svc"
cat > "$T/bin/systemctl" <<STUB
#!/bin/sh
S="$T/svc"
case "\$1 \$2" in
  "is-active --quiet") [ -f "\$S/active" ] ;;
  "is-active fprintd.service") if [ -f "\$S/fp_active" ]; then echo active; else echo inactive; exit 3; fi ;;
  "is-enabled fprintd.service")
      if [ -f "\$S/masked" ]; then echo masked; elif [ -f "\$S/rmasked" ]; then echo masked-runtime
      elif [ -f "\$S/fp_base" ]; then cat "\$S/fp_base"; elif [ -f "\$S/fp_enabled" ]; then echo enabled
      else echo static; fi ;;
  "mask fprintd.service") touch "\$S/masked" ;;
  "mask --runtime") touch "\$S/rmasked" ;;
  "unmask fprintd.service") rm -f "\$S/masked" "\$S/rmasked" ;;
  "enable fprintd.service") touch "\$S/fp_enabled" ;;
  "enable --runtime") echo enabled-runtime > "\$S/fp_base" ;;
  "start fprintd.service") touch "\$S/fp_active" ;;
  "stop fprintd.service") rm -f "\$S/fp_active" ;;
  "restart cros-fprintd.service") if [ -f "\$S/will_start" ]; then touch "\$S/active"; else rm -f "\$S/active"; fi ;;
  "disable --now") rm -f "\$S/active" ;;
  *) exit 0 ;;
esac
STUB
printf '#!/bin/sh\nexit 0\n' > "$T/bin/udevadm"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/dnf"
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"
D="$T/root"
run() { FPRINTD_CHECK_ROOT="$T/sys" FPRINTD_DESTDIR="$D" bash "$INSTALLER" "$@" </dev/null >"$T/out" 2>&1; }
BIN=$D/usr/local/libexec/cros-fprintd
UNIT=$D/etc/systemd/system/cros-fprintd.service
RULE=$D/etc/udev/rules.d/70-cros-fprintd.rules
DROPINS=$D/etc/systemd/system/cros-fprintd.service.d

echo "== unsupported configuration (deep sleep) is refused"
fake_sys "s2idle [deep]"; rm -rf "$D" "$T/svc"/*
run; rc=$?
check '[ $rc -ne 0 ]' "installer fails"
check '[ ! -e "$BIN" ] && [ ! -e "$UNIT" ]' "nothing installed"
check 'grep -q "deep sleep (S3) is not supported" "$T/out"' "reason is reported"

echo "== fresh install, service fails to start -> full rollback"
fake_sys "[s2idle] deep"; rm -rf "$D" "$T/svc"/*
run; rc=$?
check '[ $rc -ne 0 ]' "installer fails"
check 'grep -q "restoring the previous state" "$T/out"' "rollback announced"
check '[ ! -e "$BIN" ] && [ ! -e "$UNIT" ] && [ ! -e "$RULE" ]' "no files left behind"
check '[ ! -f "$T/svc/masked" ]' "stock fprintd unmasked again"

echo "== upgrade, new version fails to start -> previous version restored"
rm -rf "$D" "$T/svc"/*
mkdir -p "$(dirname "$BIN")" "$(dirname "$UNIT")" "$(dirname "$RULE")"
echo "OLD DAEMON" > "$BIN"; echo "OLD UNIT" > "$UNIT"; echo "OLD RULE" > "$RULE"
touch "$T/svc/masked" "$T/svc/active"
run; rc=$?
check '[ $rc -ne 0 ]' "installer fails"
check '[ "$(cat "$BIN")" = "OLD DAEMON" ] && [ "$(cat "$UNIT")" = "OLD UNIT" ] && [ "$(cat "$RULE")" = "OLD RULE" ]' \
      "previous files restored"
check '[ -f "$T/svc/masked" ]' "fprintd stays masked (it was masked before)"

echo "== successful install"
rm -rf "$D" "$T/svc"/*; touch "$T/svc/will_start"
mkdir -p "$DROPINS"; echo "legacy" > "$DROPINS/stop-on-suspend.conf"
run; rc=$?
check '[ $rc -eq 0 ]' "installer succeeds"
check 'cmp -s "$BIN" "$HERE/../cros-fprintd"' "daemon installed"
check '[ -e "$UNIT" ] && [ -e "$RULE" ]' "unit and udev rule installed"
check '[ -f "$T/svc/masked" ]' "stock fprintd masked"
check '[ ! -e "$DROPINS/stop-on-suspend.conf" ]' "legacy S3 drop-in removed"

echo "== uninstall keeps foreign drop-ins and the state, --purge removes the state"
mkdir -p "$DROPINS" "$D/var/lib/cros-fprintd"
echo "mine" > "$DROPINS/my-own.conf"; echo "legacy" > "$DROPINS/stop-on-suspend.conf"
echo seed > "$D/var/lib/cros-fprintd/seed"
run --uninstall; rc=$?
check '[ $rc -eq 0 ]' "uninstaller succeeds"
check '[ ! -e "$BIN" ] && [ ! -e "$UNIT" ] && [ ! -e "$RULE" ]' "project files removed"
check '[ -e "$DROPINS/my-own.conf" ]' "foreign drop-in kept"
check '[ ! -e "$DROPINS/stop-on-suspend.conf" ]' "own legacy drop-in removed"
check 'grep -q "didn.t create" "$T/out"' "kept drop-in is reported"
check '[ -e "$D/var/lib/cros-fprintd/seed" ]' "state kept without --purge"
check '[ ! -f "$T/svc/masked" ]' "stock fprintd unmasked"
run --uninstall --purge
check '[ ! -e "$D/var/lib/cros-fprintd" ]' "--purge removes the state"

echo "== administrator had masked fprintd on purpose -> stays masked after uninstall"
rm -rf "$D" "$T/svc"/*; touch "$T/svc/will_start" "$T/svc/masked"
run; run --uninstall
check '[ -f "$T/svc/masked" ]' "fprintd still masked"

echo "== administrator had enabled and started fprintd -> restored after uninstall"
rm -rf "$D" "$T/svc"/*; touch "$T/svc/will_start" "$T/svc/fp_enabled" "$T/svc/fp_active"
run
check '[ -f "$T/svc/masked" ] && [ ! -f "$T/svc/fp_active" ]' "fprintd masked and stopped while installed"
run --uninstall
check '[ ! -f "$T/svc/masked" ] && [ -f "$T/svc/fp_enabled" ] && [ -f "$T/svc/fp_active" ]' \
      "fprintd unmasked, enabled and running again"

echo "== failed fresh install restores an enabled, running fprintd"
rm -rf "$D" "$T/svc"/*; touch "$T/svc/fp_enabled" "$T/svc/fp_active"
run
check '[ ! -f "$T/svc/masked" ] && [ -f "$T/svc/fp_enabled" ] && [ -f "$T/svc/fp_active" ]' \
      "fprintd unmasked, enabled and running again after rollback"

echo "== upgrade keeps the original record; install from an older version records 'unknown'"
rm -rf "$D" "$T/svc"/*; touch "$T/svc/will_start" "$T/svc/fp_enabled"
run; first="$(cat "$D/var/lib/cros-fprintd/installer-fprintd-state")"
run; second="$(cat "$D/var/lib/cros-fprintd/installer-fprintd-state")"
check '[ "$first" = "$second" ] && [ "${first%% *}" = enabled ]' "upgrade keeps the first record ($second)"
rm -f "$D/var/lib/cros-fprintd/installer-fprintd-state"
run
check '[ "$(cut -d" " -f1 "$D/var/lib/cros-fprintd/installer-fprintd-state")" = unknown ]' \
      "upgrade from a version without a record stores 'unknown'"
run --uninstall
check '[ ! -f "$T/svc/masked" ] && grep -q "wasn.t recorded\|unknown" "$T/out"' "unknown state: unmasked, as before"

echo "== runtime mask is restored as a runtime mask"
rm -rf "$D" "$T/svc"/*; touch "$T/svc/will_start" "$T/svc/rmasked"
run; run --uninstall
check '[ -f "$T/svc/rmasked" ] && [ ! -f "$T/svc/masked" ]' "masked-runtime restored (not a persistent mask)"

echo "== runtime enablement is restored as runtime enablement"
rm -rf "$D" "$T/svc"/*; touch "$T/svc/will_start"; echo enabled-runtime > "$T/svc/fp_base"
run; rm -f "$T/svc/fp_base"; run --uninstall
check '[ "$(cat "$T/svc/fp_base" 2>/dev/null)" = enabled-runtime ] && [ ! -f "$T/svc/masked" ]' \
      "enabled-runtime restored"

echo "== runtime state from an earlier boot is not re-created"
rm -rf "$D" "$T/svc"/*; touch "$T/svc/will_start" "$T/svc/rmasked"
run; rm -f "$T/svc/rmasked"          # a reboot clears the runtime mask
sed -i 's/ [^ ]*$/ some-earlier-boot/' "$D/var/lib/cros-fprintd/installer-fprintd-state"
run --uninstall
check '[ ! -f "$T/svc/rmasked" ] && [ ! -f "$T/svc/masked" ]' "expired runtime mask not re-applied"

echo "== a state that can't be restored exactly is refused before any change"
rm -rf "$D" "$T/svc"/*; touch "$T/svc/will_start"; echo linked > "$T/svc/fp_base"
run; rc=$?
check '[ $rc -ne 0 ] && grep -q "Nothing was changed" "$T/out"' "installer refuses 'linked'"
check '[ ! -e "$BIN" ] && [ ! -f "$T/svc/masked" ]' "nothing installed, fprintd untouched"

echo "== failure while recording the state rolls the installation back"
rm -rf "$D" "$T/svc"/*; touch "$T/svc/will_start"
mkdir -p "$D/var/lib"; echo "not a directory" > "$D/var/lib/cros-fprintd"
run; rc=$?
check '[ $rc -ne 0 ] && grep -q "restoring the previous state" "$T/out"' "installer fails and rolls back"
check '[ ! -e "$BIN" ] && [ ! -e "$UNIT" ] && [ ! -f "$T/svc/masked" ]' "no half-finished installation remains"

echo "RESULT: $([ $FAILED -eq 0 ] && echo "ALL PASSED" || echo FAILED)"
exit $FAILED
