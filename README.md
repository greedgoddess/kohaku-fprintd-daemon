# kohaku-fprintd-daemon

Fingerprint unlock for the **Samsung Galaxy Chromebook (Kohaku)** running Fedora with MrChromebox firmware: `sudo`, the GNOME lock screen, and the `fprintd-*` tools use the built-in fingerprint reader. The daemon, **cros-fprintd**, speaks the standard `fprintd` D-Bus API and drives the ChromeOS fingerprint MCU directly through `/dev/cros_fp`.

The first part of this README is for installing and using it. The [Development](#development) part covers how it works, the tests and tools, and releases.

## Read this first

**This is experimental software, version 0.8.0. Use it with caution.**

- **Built for one laptop.** It was made for, and tested on, exactly one machine: the author's Samsung Galaxy Chromebook (Kohaku) with MrChromebox firmware 2609.3, Fedora 45 and GNOME Shell 51. The installer refuses anything outside that configuration, and even within it, your machine may behave differently.
- **Not regularly maintained.** This is a personal project, published in case it helps someone. There is no promise of updates, fixes or answers to issues and pull requests. Fedora, GNOME or firmware updates may break it at any time. You're welcome to fork it; it's MIT-licensed.
- **It touches sensitive parts of the system.** The daemon runs as root and talks directly to the fingerprint chip. The installer replaces the stock `fprintd` service. Enabling fingerprint changes your PAM login configuration. Keep a root shell open the first time you change PAM settings, and keep your password: it always remains a fallback.
- **It handles biometric data, and its security hasn't been audited.** Treat fingerprint unlock as a convenience, not as a security feature you rely on.

## How this was made

This project was built with heavy use of AI. The daemon, installer, probe tools, tests and documentation were written largely by an AI assistant (Claude, by Anthropic) in a long working conversation with the author. The author directed the work, made the decisions, and ran every hardware test on the actual laptop. The hardware findings in this repository (command versions, pin readings, suspend behaviour) come from those real tests, not from the AI's assumptions.

The code has not been reviewed by an independent expert. Read it before you run it as root, especially `install.sh` and `cros-fprintd`.

## Supported configuration

The installer checks all of these and refuses to install otherwise:

| Requirement | How to check |
|---|---|
| Samsung Galaxy Chromebook (Kohaku) with a working fingerprint reader | `ls /dev/cros_fp` |
| MrChromebox UEFI firmware **2609.3 or newer** | `cat /sys/class/dmi/id/bios_version` |
| Suspend-to-idle (s2idle) as the default sleep mode | `cat /sys/power/mem_sleep` shows `[s2idle]` |
| Working S0ix | the installer verifies it, with a 20-second test suspend if needed |

**Deep sleep (S3) is not supported.** On Kohaku, the firmware switches the fingerprint chip off when resuming from S3, and it only comes back after a full power-off.

Other Chromebooks with a ChromeOS fingerprint chip may work, but only Kohaku has been tested.

## What works

| | |
|---|---|
| Enrol and verify fingers (`fprintd-enroll`, `fprintd-verify`) | ✅ |
| `sudo` | ✅ |
| GNOME lock screen | ✅ |
| Fingerprint after suspend | ✅ |
| Fingers kept across reboots | ✅ |
| GNOME login screen (after boot or logout) | ❌ Password only. GNOME uses fingerprint only to re-authenticate an existing session |
| polkit prompts, GNOME Settings > Fingerprint Login | Not yet tested |

## Install

Update your firmware first, if needed, with the [MrChromebox Firmware Utility Script](https://docs.mrchromebox.tech/docs/fwscript). Then download and run the latest release:

```bash
curl -LO https://github.com/greedgoddess/kohaku-fprintd-daemon/releases/latest/download/kohaku-fprintd.tar.gz
tar -xzf kohaku-fprintd.tar.gz
cd kohaku-fprintd-*/
sudo ./install.sh
```

Releases are the versions that were tested on the author's laptop. Cloning `main` gives you the current, possibly untested, development state instead.

To only check whether your laptop qualifies, without installing anything: `sudo ./install.sh --check`.

Turn on fingerprint in PAM if the installer says it's off. Keep a second root shell open while you do it:

```bash
sudo authselect enable-feature with-fingerprint
sudo authselect apply-changes
```

Then enrol a finger, test it, and **log out and back in once**:

```bash
fprintd-enroll      # about a dozen touches; lift and move the finger slightly between touches
fprintd-verify
```

Your password always keeps working as a fallback.

## Uninstall

```bash
sudo ./install.sh --uninstall           # keeps your enrolled fingers
sudo ./install.sh --uninstall --purge   # also deletes them
```

## Troubleshooting

- **Logs:** `journalctl -u cros-fprintd -b`
- **The installer reports a failed requirement:** each line says what's missing. The usual fix is a firmware update, or switching back to s2idle if you changed the sleep mode.
- **The reader stopped working after a suspend:** check `cat /sys/power/mem_sleep`. If `deep` is selected, that's the unsupported S3 mode. A full power-off brings the reader back.
- **The lock screen doesn't offer fingerprint:** check that `gsettings get org.gnome.login-screen enable-fingerprint-authentication` prints `true` (enabling `with-fingerprint` in PAM sets it), and log out and back in once. Press a key on the lock screen first, so the password field shows.

## Security

- **Fingerprint matching runs on the fingerprint chip itself.** Your fingerprint never leaves it unencrypted.
- **The encrypted templates and the key material are root-only** under `/var/lib/cros-fprintd`. Anyone with root can read them, which is the same trust model as most Linux fingerprint setups.
- **Treat it as a convenience unlock,** not a replacement for a strong password. Details are under [Security details](#security-details).

## Development

This part is for working on the code. Bug reports and contributions are welcome as GitHub issues and pull requests.

### Support checks

`install.sh` enforces the [supported configuration](#supported-configuration). It checks the firmware version, the FADT "Low Power S0 Idle" flag, the LPS0 ACPI device and the default sleep mode, and confirms that S0ix is actually reached, running a 20-second `rtcwake -m freeze` test suspend if S0ix hasn't been entered since boot. `sudo ./install.sh --check` runs the checks alone.

### How it works

- **Boot:** once per boot the MCU is given a 32-byte secret, the seed, stored root-only in `/var/lib/cros-fprintd/seed`. The MCU encrypts every template it hands out with a key derived from this seed.
- **Per user:** each user gets a 32-byte id, `HMAC-SHA256(seed, "cros-fprintd user:" + username)`. Before every enrol or verify, the daemon sets that id as the MCU's user context, which wipes the templates the MCU holds, and then loads that user's saved templates.
- **On the chip:** enrolment and matching run on the MCU. Progress and results arrive as fingerprint events read from `/dev/cros_fp`.
- **After matching:** the firmware updates a template every time it matches, and it cannot be told not to. After each session the daemon reads changed ("dirty") templates back out and rewrites the files.
- **Access rule (no polkit):** a caller may act for a user only if it runs as that user or as root. `pam_fprintd` under `sudo`, GDM and polkit runs as root, and GNOME Settings runs as the user.

It's a single Python file (`cros-fprintd`) using PyGObject. It replaces the stock `fprintd`, which is masked during install. `pam_fprintd` and the client tools from Fedora's `fprintd` packages are still used.

### Login screen

GNOME's login screen (after a boot or a logout) doesn't offer fingerprint, and that's GNOME's decision, not a fault in this daemon. In GNOME Shell 51, the login code (`gdm/authServicesLegacy.js` in `libshell-51.so`) only connects its fingerprint manager when it is re-authenticating an existing session:

```js
_connectFingerprintManager() {
    if (!this._reauthOnly)
        return;
    ...
```

So the lock screen asks the daemon about the reader, while the login screen never does, and there's no setting to change that. Log in with your password, then use the fingerprint for the lock screen and `sudo`.

### Repository layout

| Path | What |
|---|---|
| `cros-fprintd` | the daemon (single Python file, PyGObject) |
| `install.sh` | installer with the support checks (`--check`, `--uninstall`) |
| `systemd/`, `udev/` | service unit, and the udev rule that starts the daemon when `/dev/cros_fp` appears |
| `scripts/make-release.sh` | builds the release tarball |
| `tests/` | D-Bus API tests against a simulated MCU |
| `tools/fpprobe/` | small C programs used to work out the MCU protocol |
| `docs/SUSPEND-INVESTIGATION.md` | the S3 investigation, and its resolution with firmware 2609.3 |

### Working on it

- `tests/run-fake-tests.sh` runs the D-Bus API tests against a simulated MCU (`--fake-mcu`) on a private session bus, with no hardware or root needed.
- `FPRINTD_CHECK_ROOT=/some/fake/root ./install.sh --check` runs the installer's checks against a fake `/sys` tree. That's useful for testing the support checks without the hardware.
- With `-v`, the daemon logs every D-Bus request with the caller's uid. Refused requests are always logged as warnings. To turn it on for the installed service:

  ```bash
  printf '[Service]\nExecStart=\nExecStart=/usr/bin/python3 /usr/local/libexec/cros-fprintd -v\n' | sudo tee /etc/systemd/system/cros-fprintd.service.d/debug.conf
  sudo systemctl daemon-reload && sudo systemctl restart cros-fprintd
  ```

- `tools/fpprobe/` contains probes for talking to the MCU by hand. See its README for which ones change the MCU's state.

### Releasing

The release tarball contains only the user-facing files: the daemon, installer, unit, udev rule, README, LICENSE and a `VERSION` file. Its file name stays `kohaku-fprintd.tar.gz` for every release, so the `releases/latest/download/` link in [Install](#install) always points at the newest one.

```bash
git tag -a v0.8.0 -m "v0.8.0"
git push origin v0.8.0
scripts/make-release.sh v0.8.0        # writes dist/kohaku-fprintd.tar.gz and its .sha256
gh release create v0.8.0 dist/kohaku-fprintd.tar.gz dist/kohaku-fprintd.tar.gz.sha256 \
    --title "v0.8.0" --notes "What changed, and which firmware it was tested on"
```

Without the `gh` tool, create the release on GitHub (Releases → Draft a new release → choose the tag) and attach the two files from `dist/`.

### Security details

- Matching happens on the MCU. Templates leave it only in encrypted form, and they're stored root-only.
- The encryption is only as strong as the protection of `/var/lib/cros-fprintd/seed`. Anyone with root can read the seed and the templates. That's the same trust model as most Linux fingerprint setups.
- ChromeOS uses extra firmware features to authenticate match results to the host (pairing keys, signed matches). This daemon doesn't. It trusts the match events from `/dev/cros_fp`, as `fprintd` trusts its USB readers.
- Treat fingerprint as a convenience unlock. It has only been tested with one enrolled finger against one other finger. False accept and false reject rates are unknown.
- Instead of polkit, the access rule is "same user or root". Any local user can claim the reader for themselves, and can therefore block it for others while claimed, as with `fprintd`.

### Known limitations

- **Enrolment stages:** the daemon reports 12 stages to GNOME, which is an estimate. Enrolment took 10-11 images in testing, so GNOME's progress ring may jump at the end.
- **Matching time:** the firmware rejects "match without template update". Matching time was seen to creep up slowly as templates are updated (about 130 to 180 ms). If matching gets noticeably slower over time, re-enrol the finger.
- **Template limit:** the MCU holds at most 5 templates at once, so you can enrol up to 5 fingers per user.
- **One user at a time:** the MCU has one user context, so the daemon reloads the right user's templates on every operation. Each verify starts by loading every saved finger, 93 transfers of 512 bytes per finger.
- **No polkit integration,** as described above.

### Background

This was worked out step by step on real hardware using:

- the ChromiumOS EC sources (`include/ec_commands.h`), which define the commands, structures and event bits,
- the coreboot sources for the Hatch board family (Kohaku is a Hatch variant), which name the FPMCU's reset and power pins,
- ChromeOS's `flash_fp_mcu` script, which maps those pins.

## License

[MIT](LICENSE). The ChromeOS EC command numbers and structure layouts the code relies on come from the ChromiumOS EC headers (BSD-3-Clause) and the Linux kernel's cros_ec interface. They are interface definitions, re-declared here, not copied code.
