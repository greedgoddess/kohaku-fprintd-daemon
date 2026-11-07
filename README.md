# kohaku-fprintd-daemon

Fingerprint unlock for the **Samsung Galaxy Chromebook (Kohaku)** running Fedora with MrChromebox firmware: `sudo`, the GNOME lock screen, and the `fprintd-*` tools use the built-in fingerprint reader. The daemon, **cros-fprintd**, speaks the standard `fprintd` D-Bus API and drives the ChromeOS fingerprint MCU directly through `/dev/cros_fp`.

The first part of this README is for installing and using it. The [Development](#development) part covers how it works, the tests and tools, and releases.

## Read this first

**This is experimental, pre-1.0 software. Use it with caution.** The exact version is in the `VERSION` file of each release.

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
| The **S0ix** option enabled in the firmware setup menu | press ESC at boot, open the setup menu, and look for the S0ix option. It was off on the test machine after a firmware update, because firmware updates reset all settings |
| Suspend-to-idle (s2idle) as the default sleep mode | `cat /sys/power/mem_sleep` shows `[s2idle]`. This follows automatically from the S0ix option |
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

Update your firmware first, if needed, with the [MrChromebox Firmware Utility Script](https://docs.mrchromebox.tech/docs/fwscript). Then make sure the S0ix option is enabled in the firmware setup (press ESC at boot); after a firmware update it may be off. Then download and run the latest release:

```bash
curl -LO https://github.com/greedgoddess/kohaku-fprintd-daemon/releases/latest/download/kohaku-fprintd.tar.gz
curl -LO https://github.com/greedgoddess/kohaku-fprintd-daemon/releases/latest/download/kohaku-fprintd.tar.gz.sha256
sha256sum -c kohaku-fprintd.tar.gz.sha256      # must print "kohaku-fprintd.tar.gz: OK"
tar -xzf kohaku-fprintd.tar.gz
cd kohaku-fprintd-*/
sudo ./install.sh
```

The checksum catches a damaged or incomplete download; it comes from the same place as the file, so it doesn't prove who made it. Releases are the versions that were tested on the author's laptop. Cloning `main` gives you the current, possibly untested, development state instead.

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

The uninstaller removes only what the installer created. Drop-ins of your own in `/etc/systemd/system/cros-fprintd.service.d/` stay in place.

## Troubleshooting

- **Logs:** `journalctl -u cros-fprintd -b`
- **The fingerprint option disappears now and then:** the [availability monitor](https://github.com/greedgoddess/kohaku-fprintd-daemon/tree/main/tools/monitor) (a development tool in the repository, not in the release) records when it happens and what state the service and MCU were in.
- **The installer reports a failed requirement:** each line says what's missing. The usual fix is a firmware update, or switching back to s2idle if you changed the sleep mode.
- **The reader stopped working after a suspend:** check `cat /sys/power/mem_sleep`. If it shows `[deep]`, the laptop used the unsupported S3 mode, almost always because the S0ix option in the firmware setup is off. Firmware updates reset it. Enable it (press ESC at boot), and do a full power-off to bring the reader back. `sudo ./install.sh --check` confirms the result.
- **The lock screen doesn't offer fingerprint:** check that `gsettings get org.gnome.login-screen enable-fingerprint-authentication` prints `true` (enabling `with-fingerprint` in PAM sets it), and log out and back in once. Press a key on the lock screen first, so the password field shows.

## Security

- **Fingerprint matching runs on the fingerprint chip itself.** Your fingerprint never leaves it unencrypted.
- **The encrypted templates and the key material are root-only** under `/var/lib/cros-fprintd`. Anyone with root can read them, which is the same trust model as most Linux fingerprint setups.
- **After 5 failed matches in a row,** fingerprint is refused for 10 minutes and only the password works.
- **The service runs sandboxed:** no network, no access to home directories, read-only system files, no special privileges, and no devices other than the fingerprint chip.
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
| `tools/monitor/` | availability and battery monitor: logs when and why the reader becomes unavailable, and the battery drain during each sleep |
| `docs/SUSPEND-INVESTIGATION.md` | the S3 investigation, and its resolution with firmware 2609.3 |

### Working on it

- `tests/run-fake-tests.sh` runs all tests on a private session bus, with no hardware or root needed. It waits until each daemon is on the bus instead of sleeping, and cleans up after itself. The suites are:
  - **storage:** private files, size limits, deletion races;
  - **D-Bus API:** the main suite;
  - **lockout;**
  - **invalid match index;**
  - **worker lifetime:** a released session keeps the device busy until its worker has ended;
  - **delete during verify:** a print deleted mid-verify neither matches nor comes back;
  - **installer:** refusal of unsupported setups, rollback on a failed fresh install and on a failed upgrade, uninstall keeping foreign drop-ins, `--purge`. It runs in a temporary directory with stubbed `systemctl`;
  - **unsafe seed:** a world-readable seed must be refused.

  The simulated MCU lives in `tests/fake_daemon.py`, which loads the daemon and swaps in the fake. The shipped daemon itself contains no test hooks.
- `systemd-analyze security cros-fprintd` shows how well the service is sandboxed. The unit scores about 1.1 ("OK"); without the hardening it's 8.2 ("EXPOSED").
- `FPRINTD_CHECK_ROOT=/some/fake/root ./install.sh --check` runs the installer's checks against a fake `/sys` tree. That's useful for testing the support checks without the hardware.
- With `-v`, the daemon logs every D-Bus request with the caller's uid. Refused requests are always logged as warnings. To turn it on for the installed service:

  ```bash
  printf '[Service]\nExecStart=\nExecStart=/usr/bin/python3 /usr/local/libexec/cros-fprintd -v\n' | sudo tee /etc/systemd/system/cros-fprintd.service.d/debug.conf
  sudo systemctl daemon-reload && sudo systemctl restart cros-fprintd
  ```

- `tools/fpprobe/` contains probes for talking to the MCU by hand. See its README for which ones change the MCU's state.
- `tools/monitor/` contains an availability monitor: a small service that logs state changes, suspend/resume and relevant journal lines, plus a `mark` command to note when something went wrong and a `battery` command for the average standby drain.

### Releasing

The release tarball contains only the user-facing files: the daemon, installer, unit, udev rule, README, LICENSE and a `VERSION` file with the tag and commit. Its file name stays `kohaku-fprintd.tar.gz` for every release, so the `releases/latest/download/` link in [Install](#install) always points at the newest one.

`scripts/make-release.sh` builds it from the tag, not from the working tree. Before packing, it:

1. **Checks the tag:** if the tag is signed, it verifies the signature. An unsigned tag gives a warning.
2. **Scans for secrets:** it refuses to build if anything tracked at the tag looks like private data (`seed`, `*.bin`, keys) or contains secrets such as private keys or access tokens.
3. **Builds reproducibly:** files are sorted, timestamps come from the commit, and owners are normalised. The same tag always gives a byte-identical tarball, so anyone can rebuild it and compare the checksum.

**Signed tags with your SSH key** (one-time setup). The same key you push with can sign tags. Add it on GitHub as a *signing* key too, so tags show as "Verified":

```bash
git config --global gpg.format ssh
git config --global user.signingkey ~/.ssh/id_ed25519.pub
echo "$(git config user.email) $(cat ~/.ssh/id_ed25519.pub)" >> ~/.ssh/allowed_signers
git config --global gpg.ssh.allowedSignersFile ~/.ssh/allowed_signers
```

Then, for each release:

```bash
git tag -s v0.9.0 -m "v0.9.0"
git push origin v0.9.0
scripts/make-release.sh v0.9.0        # writes dist/kohaku-fprintd.tar.gz and its .sha256
gh release create v0.9.0 dist/kohaku-fprintd.tar.gz dist/kohaku-fprintd.tar.gz.sha256 \
    --title "v0.9.0" --notes "What changed, and which firmware it was tested on"
```

Without the `gh` tool, create the release on GitHub (Releases → Draft a new release → choose the tag) and attach the two files from `dist/`.

### Security details

- Matching happens on the MCU. Templates leave it only in encrypted form, and they're stored root-only.
- The encryption is only as strong as the protection of `/var/lib/cros-fprintd/seed`. Anyone with root can read the seed and the templates. That's the same trust model as most Linux fingerprint setups.
- ChromeOS uses extra firmware features to authenticate match results to the host (pairing keys, signed matches). This daemon doesn't. It trusts the match events from `/dev/cros_fp`, as `fprintd` trusts its USB readers.
- Treat fingerprint as a convenience unlock. It has only been tested with one enrolled finger against one other finger. False accept and false reject rates are unknown.
- Instead of polkit, the access rule is "same user or root". Any local user can claim the reader for themselves, and can therefore block it for others while claimed, as with `fprintd`.
- **Lockout:** after 5 consecutive failed matches for a user, `VerifyStart` is refused for 10 minutes. The count is kept in memory, so restarting the service resets it. Each attempt takes only about a quarter of a second, so without a limit someone could try many fake fingerprints quickly.
- **Sandboxing:** the unit follows the approach of the stock `fprintd.service` (strict read-only system, kernel and clock protection, a private state directory, device allow-list) and goes further where this daemon allows it:
  - **Network:** none (`PrivateNetwork=yes`); only Unix sockets for D-Bus.
  - **Privileges:** no capabilities at all. It runs as root only because of D-Bus policy and file ownership.
  - **Devices:** `/dev/cros_fp` is the only device it can open.
  - **System calls:** limited to `@system-service`; anything else fails with `EPERM`.
  - **Memory:** no memory that is both writable and executable (`MemoryDenyWriteExecute=yes`). The test suites pass with the daemon under the kernel's equivalent restriction.
  - **Processes and IPC:** only its own processes are visible in `/proc`, and there's no System V IPC and no shared kernel keyring.
  - **Python:** runs in isolated mode (`python3 -I`), which ignores `PYTHON*` environment variables and user site-packages.
- **Error messages:** unexpected errors are logged to the journal; D-Bus callers only get a generic message, so no file paths or internals leak to unprivileged users.
- **Match results are checked:** a match counts only if the MCU names a template index that the daemon actually loaded. Anything else is treated as an error and counts towards the lockout.
- **Private files:**
  - The seed and templates are read without following symlinks.
  - They must be regular files owned by the service user, with no group or other permissions; otherwise the daemon refuses them.
  - Templates are limited in size.
  - State directories are created with mode 0700, and tightened if they're more open.
  - Writes go through unpredictable temporary files (`mkstemp`) and an atomic rename.
- **No resurrected prints:** deleting a user's fingers bumps a counter. A verify or enrol that was already running then can't write its templates back afterwards.
- **One worker at a time:** releasing the device stops a running verify or enrol, and the device stays busy until that worker has really finished, so two workers never use the MCU at once.
- **Installer rollback:** before overwriting anything, the installer backs up the previous files. If any step fails, or the new service doesn't come up, it restores them, and unmasks the stock `fprintd` if it wasn't masked before.

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
