# kohaku-fprintd-daemon

A fingerprint service for the **Samsung Galaxy Chromebook (board: Kohaku)** running ordinary Linux. It speaks the standard `fprintd` D-Bus API, so the `fprintd-*` tools, `pam_fprintd` (`sudo`) and the GNOME lock screen can use the built-in reader without changes.

The reader on ChromeOS devices is not a USB sensor that libfprint knows. It sits behind a small fingerprint microcontroller (the "FPMCU"), which the kernel exposes as `/dev/cros_fp`. Enrolment and matching run on that chip. This daemon drives it directly over the ChromeOS EC protocol.

## Status

| | |
|---|---|
| Enrol, verify, list fingers | ✅ Working (`fprintd-enroll`, `fprintd-verify`, `fprintd-list`) |
| `sudo` via `pam_fprintd` | ✅ Working, password stays as fallback |
| GNOME lock screen | ✅ Working (GNOME Shell 51) |
| GNOME login screen (after boot or logout) | ❌ Password only. GNOME Shell 51 uses fingerprint for re-authentication only, see [Login screen](#login-screen) |
| polkit prompts, GNOME Settings > Fingerprint Login | Expected to work (same `fprintd` API), not yet tested |
| Enrolled fingers survive reboots | ✅ Encrypted templates are saved and reloaded |
| Reader after **suspend** | ⚠️ Stops working until a full power-off. See [Suspend](#suspend) |

Tested on one machine:

- Samsung Galaxy Chromebook (Kohaku), MrChromebox UEFI firmware 2503.0
- Fedora 45, GNOME Shell 51.1
- FPMCU firmware `dartmonkey` (RO v2.0.2887, RW v2.0.28102), FPC sensor (model `0x140c`)

Other Chromebooks with a `cros_fp` fingerprint MCU may work, but nothing else has been tested. The daemon has no Kohaku-specific code. Only the suspend findings are board-specific.

## How it works

- **Boot:** once per boot the MCU is given a 32-byte secret, the seed, stored root-only in `/var/lib/cros-fprintd/seed`. The MCU encrypts every template it hands out with a key derived from this seed.
- **Per user:** each user gets a 32-byte id, `HMAC-SHA256(seed, "cros-fprintd user:" + username)`. Before every enrol or verify, the daemon sets that id as the MCU's user context, which wipes the templates the MCU holds, and then loads that user's saved templates.
- **On the chip:** enrolment and matching run on the MCU. Progress and results arrive as fingerprint events read from `/dev/cros_fp`.
- **After matching:** the firmware updates a template every time it matches, and it cannot be told not to. After each session the daemon reads changed ("dirty") templates back out and rewrites the files.
- **Access rule (no polkit):** a caller may act for a user only if it runs as that user or as root. `pam_fprintd` under `sudo`, GDM and polkit runs as root, and GNOME Settings runs as the user.

It's a single Python file (`cros-fprintd`) using PyGObject. It replaces the stock `fprintd`, which is masked during install. `pam_fprintd` and the client tools from Fedora's `fprintd` packages are still used.

## Requirements

- A Chromebook whose kernel log shows `CrOS Fingerprint MCU detected`, and where `/dev/cros_fp` exists.
- Fedora (the installer uses `dnf`). Other distributions should work with the packages `fprintd`, `fprintd-pam` (or your distribution's `pam_fprintd`) and `python3-gobject`, installed by hand.
- A reader that is alive. After a deep suspend it isn't, until the next full power-off (see below). Check with `tools/fpprobe` (`make && ./fpprobe7`) or simply `ls /dev/cros_fp` after a fresh boot.

## Install

```bash
git clone https://github.com/greedgoddess/kohaku-fprintd-daemon.git
cd kohaku-fprintd-daemon
sudo ./install.sh
```

The installer copies the daemon to `/usr/local/libexec/cros-fprintd` and installs the systemd unit plus a stop-on-suspend drop-in. It masks the stock `fprintd.service` and starts the service.

The MCU accepts **one seed per boot**. If you have run the probe tools (`fpprobe3`) since the last boot, either reboot first, or pass the seed file they used: `sudo ./install.sh tools/fpprobe/seed.bin`. Without this, the daemon refuses to use a different seed, because fingers enrolled under the wrong seed couldn't be decrypted after the next boot.

## Use

```bash
fprintd-enroll            # about a dozen touches; lift and move the finger slightly between touches
fprintd-verify
fprintd-list $USER
```

GNOME Settings > System > Users > Fingerprint Login should work too, but hasn't been tested yet.

**Enable fingerprint in PAM (required).** On the test machine the `with-fingerprint` feature was not enabled, even though `fprintd-pam` was installed. Without it, `fingerprint-auth` doesn't contain `pam_fprintd`, and authselect keeps GNOME's `enable-fingerprint-authentication` setting switched off. Check with `authselect current`; if `with-fingerprint` isn't listed:

```bash
sudo authselect enable-feature with-fingerprint
sudo authselect apply-changes
gsettings get org.gnome.login-screen enable-fingerprint-authentication   # should now print true
```

Keep a root shell open the first time you change PAM settings. `pam_fprintd` is used as `sufficient`, so the password always remains as a fallback.

**Then log out and back in once,** so GNOME Shell picks up the reader. After that, `sudo` and the lock screen accept your fingerprint.

## Login screen

GNOME's login screen (after a boot or a logout) doesn't offer fingerprint, and that's GNOME's decision, not a fault in this daemon. In GNOME Shell 51, the login code (`gdm/authServicesLegacy.js` in `libshell-51.so`) only connects its fingerprint manager when it is re-authenticating an existing session:

```js
_connectFingerprintManager() {
    if (!this._reauthOnly)
        return;
    ...
```

So the lock screen asks the daemon about the reader, while the login screen never does, and there's no setting to change that. Log in with your password, then use the fingerprint for the lock screen and `sudo`.

## Suspend

On this machine the fingerprint MCU **stops responding after deep sleep (S3)**. Upstream coreboot documents this as a known limitation for Kohaku: the firmware's S3 resume path powers the fingerprint MCU off. It doesn't come back until a full power-off. Rebinding the driver, resetting it, or power-cycling it from software don't help. The details are in [docs/SUSPEND-INVESTIGATION.md](docs/SUSPEND-INVESTIGATION.md).

The installed drop-in (`systemd/stop-on-suspend.conf`) therefore stops the daemon before every suspend. After waking, nothing offers fingerprint login, so `sudo`, the lock screen and polkit go straight to the password. A full shutdown and boot brings fingerprint back.

- To get fingerprint back: shut down completely (not restart, not suspend), wait about 30 seconds, and boot.
- To keep the daemon running across suspend anyway, for example if your machine behaves differently: `sudo rm /etc/systemd/system/cros-fprintd.service.d/stop-on-suspend.conf && sudo systemctl daemon-reload`. If the MCU then dies, the daemon reports an error within about a second, and PAM falls back to the password.
- `s2idle` keeps the reader alive, but on this machine the laptop then wakes up by itself after about 10 seconds. It never reaches the processor's deep idle state, so it isn't a usable sleep mode. Leave `mem_sleep` at `deep`.

## Uninstall

```bash
sudo ./install.sh --uninstall           # keeps /var/lib/cros-fprintd
sudo ./install.sh --uninstall --purge   # also deletes the seed and enrolled templates
```

This unmasks the stock `fprintd`. If you enabled it, turn off fingerprint in PAM with `sudo authselect disable-feature with-fingerprint`.

## Files and state

| Path | What |
|---|---|
| `/usr/local/libexec/cros-fprintd` | the daemon |
| `/etc/systemd/system/cros-fprintd.service` | systemd unit (`Type=dbus`, owns `net.reactivated.Fprint`) |
| `/etc/systemd/system/cros-fprintd.service.d/stop-on-suspend.conf` | stops the daemon before sleep |
| `/etc/udev/rules.d/70-cros-fprintd.rules` | starts the daemon once `/dev/cros_fp` appears during boot |
| `/var/lib/cros-fprintd/seed` | 32-byte seed, mode 0600 |
| `/var/lib/cros-fprintd/users/<user>/<finger>.bin` | encrypted templates (47,616 bytes each on this sensor), mode 0600 |
| `/var/lib/cros-fprintd/users/<user>/fingers.json` | load order of the user's fingers |

## Security notes

- Matching happens on the MCU. Templates leave it only in encrypted form, and they're stored root-only.
- The encryption is only as strong as the protection of `/var/lib/cros-fprintd/seed`. Anyone with root can read the seed and the templates. That's the same trust model as most Linux fingerprint setups.
- ChromeOS uses extra firmware features to authenticate match results to the host (pairing keys, signed matches). This daemon doesn't. It trusts the match events from `/dev/cros_fp`, as `fprintd` trusts its USB readers.
- Treat fingerprint as a convenience unlock. It has only been tested with one enrolled finger against one other finger. False accept and false reject rates are unknown.
- Instead of polkit, the access rule is "same user or root". Any local user can claim the reader for themselves, and can therefore block it for others while claimed, as with `fprintd`.

## Known limitations

- **Enrolment stages:** the daemon reports 12 stages to GNOME, which is an estimate. Enrolment took 10-11 images in testing, so GNOME's progress ring may jump at the end.
- **Matching time:** the firmware rejects "match without template update". Matching time was seen to creep up slowly as templates are updated (about 130 to 180 ms). If matching gets noticeably slower over time, re-enrol the finger.
- **Template limit:** the MCU holds at most 5 templates at once, so you can enrol up to 5 fingers per user.
- **One user at a time:** the MCU has one user context, so the daemon reloads the right user's templates on every operation. Each verify starts by loading every saved finger, 93 transfers of 512 bytes per finger.
- **No polkit integration,** as described above.

## Troubleshooting

- **`journalctl -u cros-fprintd -b`** is the first place to look.
- **`MCU not ready yet`** at startup, or `ioctl ... Connection timed out` in the log, means the MCU isn't answering. This usually follows a suspend. Do a full power-off.
- **`cros-fprintd.service ... skipped, unmet condition check ConditionPathExists=/dev/cros_fp`** at boot: the reader appeared after systemd checked. The udev rule installed by `install.sh` starts the daemon when the device appears. Older installs: re-run `install.sh`.
- **The lock screen doesn't offer fingerprint:** check that `gsettings get org.gnome.login-screen enable-fingerprint-authentication` prints `true` (see "Enable fingerprint in PAM" above), and log out and back in once. The lock screen only starts the fingerprint check once the password prompt is showing, so press a key first.
- **`/dev/cros_fp` missing:** the kernel didn't detect the MCU at boot, or someone unbound the driver. A full power-off and boot normally restores it.
- **`enroll-failed` or `verify-unknown-error`:** check the log for the `ERROR` line.
- **Low-level checks:** see [tools/fpprobe](tools/fpprobe/README.md).

## Development

- `tests/run-fake-tests.sh` runs the D-Bus API tests against a simulated MCU (`--fake-mcu`) on a private session bus, with no hardware or root needed. It covers enrol, verify with retry, claim and release, errors, and file permissions.
- `cros-fprintd --session-bus --fake-mcu --state-dir /tmp/x -v` starts the daemon in the same mode by hand.
- With `-v` the daemon logs every D-Bus request with the caller's uid, which is useful to see what a client asks. Refused requests are always logged as warnings. To turn it on for the installed service:

  ```bash
  printf '[Service]\nExecStart=\nExecStart=/usr/bin/python3 /usr/local/libexec/cros-fprintd -v\n' | sudo tee /etc/systemd/system/cros-fprintd.service.d/debug.conf
  sudo systemctl daemon-reload && sudo systemctl restart cros-fprintd
  ```

  Remove `debug.conf` and reload to turn it off again.
- `tools/fpprobe/` contains the small C programs used to work out the MCU protocol on real hardware.

## Background

This was worked out step by step on real hardware using:

- the ChromiumOS EC sources (`include/ec_commands.h`), which define the commands, structures and event bits,
- the coreboot sources for the Hatch board family (Kohaku is a Hatch variant), which name the FPMCU's reset and power pins,
- ChromeOS's `flash_fp_mcu` script, which maps those pins.

## License

No license has been chosen yet. Until one is added, default copyright rules apply. If you want others to reuse or contribute, add a `LICENSE` file, for example MIT or GPL-2.0-or-later.
